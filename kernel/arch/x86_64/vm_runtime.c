// kernel/arch/x86_64/vm_runtime — the C `kmain` for the x86-64 paging proof (vm_x86_demo).
//
// In 64-bit long mode (reached from boot.S, which already identity-maps the low 1 GiB with
// 2 MiB pages and runs us at 1 MiB): bring up COM1, install a minimal IDT with #GP (13) and
// #PF (14) handlers that print a marker over COM1 and halt (so a paging bug is DIAGNOSED, not
// a silent triple-fault reboot), enable EFER.NXE (so a PTE_NX bit would be legal — the demo
// itself sets no NX, but enabling NXE makes bit 63 non-reserved and documents the path), then:
//
//   1. call the MC `vm_x86_build`, which builds a FRESH PML4 (identity low 1 GiB + a 4 KiB
//      sentinel mapping at 3 GiB) and software-walks it (page_table_lookup) to assert the
//      translation BEFORE any CR3 reload — that alone satisfies X2's "software page-table
//      walk can support user-copy validation";
//   2. load the new PML4 into CR3 (the kernel stays mapped via the identity 1 GiB, so the
//      next instruction fetch survives), flushing the TLB;
//   3. read the sentinel back THROUGH the 3 GiB test VA — reachable ONLY through the new
//      tables' translation — and compare to the known sentinel.
//
// Print X86-VM-OK iff the software walk AND the live readback both match; else X86-VM-BAD.
#include <stdint.h>

// Freestanding C runtime helpers the compiler may emit for struct init / large copies.
void *memset(void *dst, int c, unsigned long n) {
    unsigned char *p = (unsigned char *)dst;
    for (unsigned long i = 0; i < n; i++) p[i] = (unsigned char)c;
    return dst;
}
void *memcpy(void *dst, const void *src, unsigned long n) {
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    for (unsigned long i = 0; i < n; i++) d[i] = s[i];
    return dst;
}

static inline void outb(uint16_t port, uint8_t val) {
    __asm__ volatile("outb %0, %1" : : "a"(val), "Nd"(port));
}
static inline uint8_t inb(uint16_t port) {
    uint8_t r;
    __asm__ volatile("inb %1, %0" : "=a"(r) : "Nd"(port));
    return r;
}

#define COM1 0x3F8

static void serial_init(void) {
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x80);
    outb(COM1 + 0, 0x03);
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x03);
    outb(COM1 + 2, 0xC7);
    outb(COM1 + 4, 0x0B);
}
static void putc_(char c) {
    while ((inb(COM1 + 5) & 0x20) == 0) {
    }
    outb(COM1, (uint8_t)c);
}
static void puts_(const char *s) {
    while (*s) putc_(*s++);
}
static void puthex32(uint32_t v) {
    putc_('0'); putc_('x');
    for (int i = 28; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 0xf]);
}
static void puthex64(uint64_t v) {
    putc_('0'); putc_('x');
    for (int i = 60; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 0xf]);
}

static void qemu_exit(uint8_t code) { outb(0xf4, code); }
static void halt_forever(void) { for (;;) __asm__ volatile("hlt"); }

// ---- minimal long-mode IDT (256 vectors; we fill #GP=13 and #PF=14) ----

struct idt_entry {
    uint16_t off_lo;
    uint16_t sel;     // code segment selector
    uint8_t  ist;     // bits 0..2 IST index (0 = none)
    uint8_t  type_attr; // 0x8E = present, DPL0, 64-bit interrupt gate
    uint16_t off_mid;
    uint32_t off_hi;
    uint32_t zero;
} __attribute__((packed));

struct idt_ptr {
    uint16_t limit;
    uint64_t base;
} __attribute__((packed));

static struct idt_entry g_idt[256];

// boot.S's GDT: null, then CODE_SEG at offset 8. We run in CS=0x08.
#define KCODE_SEL 0x08

static void idt_set(int vec, void (*handler)(void)) {
    uint64_t addr = (uint64_t)(uintptr_t)handler;
    g_idt[vec].off_lo = (uint16_t)(addr & 0xFFFF);
    g_idt[vec].sel = KCODE_SEL;
    g_idt[vec].ist = 0;
    g_idt[vec].type_attr = 0x8E; // present, DPL=0, type=0xE (64-bit interrupt gate)
    g_idt[vec].off_mid = (uint16_t)((addr >> 16) & 0xFFFF);
    g_idt[vec].off_hi = (uint32_t)((addr >> 32) & 0xFFFFFFFF);
    g_idt[vec].zero = 0;
}

// Fault handlers: print a marker + the faulting address (CR2 for #PF) and halt. Naked so we
// never return into a faulting state; on x86 these never come back (we halt), so we do not
// bother to pop the CPU-pushed error code.
__attribute__((used)) static void on_gp(void) {
    puts_("\nX86-VM-BAD #GP\n");
    qemu_exit(1);
    halt_forever();
}
__attribute__((used)) static void on_pf(void) {
    uint64_t cr2;
    __asm__ volatile("mov %%cr2, %0" : "=r"(cr2));
    puts_("\nX86-VM-BAD #PF at "); puthex64(cr2); putc_('\n');
    qemu_exit(1);
    halt_forever();
}

__attribute__((naked, used)) static void gp_stub(void) {
    __asm__ volatile("cli\n call on_gp\n 1: hlt\n jmp 1b\n");
}
__attribute__((naked, used)) static void pf_stub(void) {
    __asm__ volatile("cli\n call on_pf\n 1: hlt\n jmp 1b\n");
}

static struct idt_ptr g_idtr;
static void idt_install(void) {
    for (int i = 0; i < 256; i++) idt_set(i, gp_stub); // default: treat as #GP marker
    idt_set(13, gp_stub);
    idt_set(14, pf_stub);
    g_idtr.limit = (uint16_t)(sizeof(g_idt) - 1);
    g_idtr.base = (uint64_t)(uintptr_t)&g_idt[0];
    __asm__ volatile("lidt %0" : : "m"(g_idtr));
}

static void enable_nxe(void) {
    // EFER (MSR 0xC0000080) bit 11 = NXE. boot.S leaves it clear; set it so a PTE_NX bit is
    // legal (non-reserved). The demo sets no NX, but this documents/enables the path.
    uint32_t lo, hi;
    __asm__ volatile("rdmsr" : "=a"(lo), "=d"(hi) : "c"(0xC0000080));
    lo |= (1u << 11);
    __asm__ volatile("wrmsr" : : "a"(lo), "d"(hi), "c"(0xC0000080));
}

// MC builds the table, writes CR3 + test frame phys through out-pointers, and returns the
// software-walk verdict (1 = ok). Out-pointers (not a struct return) keep the FFI ABI simple
// and identical across MC's C and LLVM backends.
extern uint32_t vm_x86_build(uintptr_t region, uintptr_t len, uint64_t *out_cr3, uint64_t *out_test_phys);

// Page-table backing store: 1 MiB, 4 KiB-aligned, well under the identity-mapped 1 GiB.
__attribute__((aligned(4096))) static uint8_t heap_region[1024 * 1024];

#define TEST_VA 0xC0000000UL
#define TEST_VALUE 0xCAFEBABEu

void kmain(void) {
    serial_init();
    puts_("x86-64 long mode: VM demo boot OK\n");

    idt_install();
    puts_("vm: IDT installed (#GP=13, #PF=14)\n");
    enable_nxe();

    uint64_t cr3 = 0, test_phys = 0;
    uint32_t sw_ok = vm_x86_build((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region), &cr3, &test_phys);
    puts_("vm: table built, cr3="); puthex64(cr3);
    puts_(" test_phys="); puthex64(test_phys);
    puts_(" sw_ok="); puthex32(sw_ok); putc_('\n');

    if (sw_ok != 1) {
        puts_("X86-VM-BAD (software walk)\n");
        qemu_exit(1);
        halt_forever();
    }

    // Activate the freshly built PML4. The kernel stays mapped via the identity low 1 GiB,
    // so execution continues; this reloads CR3 (full TLB flush).
    __asm__ volatile("mov %0, %%cr3" : : "r"(cr3) : "memory");
    puts_("vm: CR3 reloaded with fresh PML4\n");

    // Read the sentinel back THROUGH the 3 GiB test VA — reachable only via translation.
    volatile uint32_t *p = (volatile uint32_t *)TEST_VA;
    uint32_t got = *p;
    puts_("vm: readback through TEST_VA "); puthex32(got); putc_('\n');

    if (got == TEST_VALUE) {
        puts_("X86-VM-OK\n");
        qemu_exit(0);
    } else {
        puts_("X86-VM-BAD (readback)\n");
        qemu_exit(1);
    }
    halt_forever();
}
