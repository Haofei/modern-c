// M7 "confined QuickJS agent on x86_64 ring-3" — kernel C bring-up.
//
// The x86-64 sibling of kernel/arch/riscv64/qjs_smode_confined_runtime.c, and a sibling of M6's
// kernel/arch/x86_64/user_runtime.c. It reuses M6's ring-3 machinery verbatim — the GDT (ring0/
// ring3 + TSS), the IDT with an int-0x80 syscall gate (DPL3) and #GP/#PF diagnostics, and the
// iretq-to-ring-3 entry — but instead of a hand-assembled hello program it:
//   1. loads the REAL multi-segment QuickJS U-mode ELF (embedded as app_image[]) into an
//      ISOLATED 4-level space via app_build_x86 (the MC fixture qjs_x86_demo.mc, which wraps the
//      x86 elf_loader + uaccess + paging), which ALSO adds the kernel's low-1-GiB supervisor-only
//      identity window so long mode + the trap path survive the CR3 reload;
//   2. installs GDT/TSS/IDT, reloads CR3, and iretq's (enter_user) into the QuickJS entry;
//   3. dispatches the FULL agent syscall set in its int-0x80 handler: SYS_EXIT here (prints
//      USER-EXIT + powers off), everything else (SYS_WRITE / SYS_READ §0 ingress / SYS_GETPID /
//      SYS_SUBMIT / SYS_POLL + the mock broker) through mc_syscall — the SAME MC syscall table
//      the riscv path uses, reused verbatim; only the trap/entry asm is x86-specific.
//
// Console: COM1 is PORT-IO (not MMIO), so unlike the riscv S-mode fixture the agent's CR3 needs
// no UART page. mc_console_putc is exported for the MC SYS_WRITE handler to print JS output.
//
// SSE/FP in ring 3: boot.S enables CR4.OSFXSR/OSXMMEXCPT and clears CR0.EM (sets MP) before long
// mode, and the iretq to ring 3 changes neither CR0 nor CR4 — so SSE stays usable in ring 3,
// which QuickJS needs for double math (JS numbers are doubles). The kernel never touches XMM, so
// the agent's FP/SSE state survives across syscalls with no save/restore.
#include <stdint.h>

// ---- COM1 serial (port IO from ring 0; ring-3 never touches it) ----
static inline void outb(uint16_t port, uint8_t val) {
    __asm__ volatile("outb %0, %1" : : "a"(val), "Nd"(port));
}
static inline uint8_t inb(uint16_t port) {
    uint8_t r;
    __asm__ volatile("inb %1, %0" : "=a"(r) : "Nd"(port));
    return r;
}
#define COM1 0x3F8
// Mask every legacy-PIC IRQ line. The BIOS leaves the 8259 master PIC mapped to vectors
// 0x08..0x0F — which OVERLAP the CPU exception vectors (#DF is 0x08!). The confined agent uses
// POLLED I/O (no device interrupts), and we enable IF in ring 3, so an unmasked timer IRQ0 would
// fire as "vector 8" and be mistaken for a #DF. Masking both PICs (OCW1 = 0xFF to the data ports)
// keeps the agent's IF=1 harmless: no IRQ is ever delivered.
static void pic_mask_all(void) {
    outb(0x21, 0xFF); // master PIC data: mask IRQ0..7
    outb(0xA1, 0xFF); // slave PIC data:  mask IRQ8..15
}
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
static void puthex64(uint64_t v) {
    putc_('0'); putc_('x');
    for (int i = 60; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 0xf]);
}
static void qemu_exit(uint8_t code) { outb(0xf4, code); }
static void halt_forever(void) { for (;;) __asm__ volatile("hlt"); }

// The MC SYS_WRITE handler prints JS/agent output through this (the COM1 console).
__attribute__((used)) void mc_console_putc(uint8_t c) { putc_((char)c); }

// ---- freestanding C runtime helpers QuickJS / the MC backend may emit ----
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
void *memmove(void *dst, const void *src, unsigned long n) {
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    if (d < s) {
        for (unsigned long i = 0; i < n; i++) d[i] = s[i];
    } else {
        for (unsigned long i = n; i > 0; i--) d[i - 1] = s[i - 1];
    }
    return dst;
}

// ---- MC fixture (qjs_x86_demo.mc) ----
extern uint32_t app_build_x86(uintptr_t image_base, uintptr_t image_len,
                              uintptr_t region_base, uintptr_t region_len, uint64_t *out_cr3);
extern uint32_t app_build_status_x86(void);
extern uint64_t app_entry_x86(void);
extern uint32_t app_kernel_not_user_x86(uintptr_t kernel_va);
extern uint32_t app_entry_is_user_x86(void);
extern void     syscall_setup(void);
extern uint64_t mc_syscall(uint64_t number, uint64_t arg0, uint64_t arg1, uint64_t arg2);

// The embedded QuickJS agent ELF (the harness emits app_image.c).
extern const unsigned char app_image[];
extern const unsigned int app_image_len;

// Weak default for the §0 ingress (SYS_READ): no embedded agent source. A test that serves an
// agent.js via SYS_READ links a STRONG mc_agent_source (its embedded JS) overriding this.
__attribute__((weak)) uintptr_t mc_agent_source(uintptr_t *out_len) {
    *out_len = 0;
    return 0;
}

// The agent syscall ABI numbers (mirror user/abi.mc). SYS_EXIT is handled here (like the riscv
// trap), everything else dispatches through mc_syscall.
#define SYS_EXIT 3ULL

#define KERNEL_VA 0x100000ULL // 1 MiB: the kernel image load address

static const char *load_status_str(uint32_t s) {
    switch (s) {
        case 1: return "APP-LOAD-FAIL: BadElf\n";
        case 2: return "APP-LOAD-FAIL: TooManyPages\n";
        case 3: return "APP-LOAD-FAIL: NoFrame\n";
        case 4: return "APP-LOAD-FAIL: BadSegment\n";
        default: return "APP-LOAD-FAIL: unknown\n";
    }
}

// ========================= GDT + TSS (identical to M6 user_runtime.c) =========================
#define SEL_KCODE 0x08
#define SEL_KDATA 0x10
#define SEL_UCODE (0x18 | 3)
#define SEL_UDATA (0x20 | 3)
#define SEL_TSS   0x28

struct tss64 {
    uint32_t reserved0;
    uint64_t rsp0;
    uint64_t rsp1;
    uint64_t rsp2;
    uint64_t reserved1;
    uint64_t ist[7];
    uint64_t reserved2;
    uint16_t reserved3;
    uint16_t iomap_base;
} __attribute__((packed));

static struct tss64 g_tss;
static uint64_t g_gdt[7];

struct gdt_ptr {
    uint16_t limit;
    uint64_t base;
} __attribute__((packed));
static struct gdt_ptr g_gdtr;

static uint64_t make_seg(int code, int dpl) {
    uint64_t d = 0;
    d |= (1ULL << 44);
    d |= (1ULL << 47);
    d |= ((uint64_t)(dpl & 3)) << 45;
    if (code) {
        d |= (1ULL << 43);
        d |= (1ULL << 53);
    } else {
        d |= (1ULL << 41);
    }
    return d;
}

static void gdt_install(void) {
    g_gdt[0] = 0;
    g_gdt[1] = make_seg(1, 0);
    g_gdt[2] = make_seg(0, 0);
    g_gdt[3] = make_seg(1, 3);
    g_gdt[4] = make_seg(0, 3);

    uint64_t base = (uint64_t)(uintptr_t)&g_tss;
    uint32_t limit = (uint32_t)(sizeof(g_tss) - 1);
    uint64_t lo = 0;
    lo |= (limit & 0xFFFFULL);
    lo |= ((base & 0xFFFFFFULL) << 16);
    lo |= (0x9ULL << 40);
    lo |= (1ULL << 47);
    lo |= (((uint64_t)(limit >> 16) & 0xFULL) << 48);
    lo |= (((base >> 24) & 0xFFULL) << 56);
    g_gdt[5] = lo;
    g_gdt[6] = (base >> 32) & 0xFFFFFFFFULL;

    g_gdtr.limit = (uint16_t)(sizeof(g_gdt) - 1);
    g_gdtr.base = (uint64_t)(uintptr_t)&g_gdt[0];
    __asm__ volatile("lgdt %0" : : "m"(g_gdtr) : "memory");

    __asm__ volatile(
        "mov %0, %%ax\n"
        "mov %%ax, %%ds\n"
        "mov %%ax, %%es\n"
        "mov %%ax, %%ss\n"
        "mov %%ax, %%fs\n"
        "mov %%ax, %%gs\n"
        : : "r"((uint16_t)SEL_KDATA) : "rax");
    __asm__ volatile(
        "lea 1f(%%rip), %%rax\n"
        "push %0\n"
        "push %%rax\n"
        "lretq\n"
        "1:\n"
        : : "i"(SEL_KCODE) : "rax", "memory");

    __asm__ volatile("ltr %0" : : "r"((uint16_t)SEL_TSS));
}

// ========================= IDT (identical to M6 user_runtime.c) =========================
struct idt_entry {
    uint16_t off_lo;
    uint16_t sel;
    uint8_t  ist;
    uint8_t  type_attr;
    uint16_t off_mid;
    uint32_t off_hi;
    uint32_t zero;
} __attribute__((packed));
struct idt_ptr {
    uint16_t limit;
    uint64_t base;
} __attribute__((packed));
static struct idt_entry g_idt[256];
static struct idt_ptr g_idtr;

static void idt_set(int vec, void (*handler)(void), uint8_t dpl) {
    uint64_t addr = (uint64_t)(uintptr_t)handler;
    g_idt[vec].off_lo = (uint16_t)(addr & 0xFFFF);
    g_idt[vec].sel = SEL_KCODE;
    g_idt[vec].ist = 0;
    g_idt[vec].type_attr = (uint8_t)(0x8E | ((dpl & 3) << 5));
    g_idt[vec].off_mid = (uint16_t)((addr >> 16) & 0xFFFF);
    g_idt[vec].off_hi = (uint32_t)((addr >> 32) & 0xFFFFFFFF);
    g_idt[vec].zero = 0;
}

// Fault diagnostics: print the vector + the top stack words (faulting RIP/CS/RFLAGS) and halt,
// so a bug is DIAGNOSED rather than silently triple-faulting. Vectors that push an error code put
// it at frame[0]; the no-error-code path passes the vector via RSI. Both go through on_fault.
__attribute__((used)) static void on_fault(uint64_t *frame, uint64_t vec) {
    uint64_t cr2;
    __asm__ volatile("mov %%cr2, %0" : "=r"(cr2));
    puts_("\nQJS-X86-BAD TRAP vec="); puthex64(vec);
    puts_(" cr2="); puthex64(cr2);
    puts_(" w0="); puthex64(frame[0]);
    puts_(" w1="); puthex64(frame[1]);
    puts_(" w2="); puthex64(frame[2]); putc_('\n');
    qemu_exit(1);
    halt_forever();
}
// One stub per architectural fault vector: load RSI = vector, RDI = RSP (the saved frame), call
// on_fault. #GP(13)/#PF(14) get named gates; the rest share these. The agent uses polled I/O and
// the PIC is masked, so no device IRQ ever fires — any trap here is a real agent fault.
#define FAULT_STUB(n) \
    __attribute__((naked, used)) static void fault_stub_##n(void) { \
        __asm__ volatile("cli\n mov %%rsp, %%rdi\n mov $" #n ", %%rsi\n call on_fault\n 1: hlt\n jmp 1b\n" : : : "memory"); \
    }
FAULT_STUB(0) FAULT_STUB(1) FAULT_STUB(2) FAULT_STUB(3) FAULT_STUB(4) FAULT_STUB(5)
FAULT_STUB(6) FAULT_STUB(7) FAULT_STUB(8) FAULT_STUB(9) FAULT_STUB(10) FAULT_STUB(11)
FAULT_STUB(12) FAULT_STUB(13) FAULT_STUB(14) FAULT_STUB(15) FAULT_STUB(16) FAULT_STUB(17)
FAULT_STUB(18) FAULT_STUB(19)
__attribute__((naked, used)) static void unk_stub(void) {
    __asm__ volatile("cli\n mov %%rsp, %%rdi\n mov $255, %%rsi\n call on_fault\n 1: hlt\n jmp 1b\n" : : : "memory");
}

// ---- syscall (int $0x80) ISR ----
struct regs {
    uint64_t rdi, rsi, rdx, rcx, rbx, rax, rbp;
    uint64_t r8, r9, r10, r11, r12, r13, r14, r15;
};

__attribute__((used)) static void syscall_dispatch_x86(struct regs *r) {
    uint64_t nr = r->rax;
    if (nr == SYS_EXIT) {
        puts_("\nUSER-EXIT from ring3\n");
        qemu_exit(0);
        halt_forever();
    }
    // Everything else: the SAME MC syscall table the riscv path uses (SYS_WRITE / SYS_READ /
    // SYS_GETPID / SYS_SUBMIT / SYS_POLL). Args follow the M6 convention: RDI/RSI/RDX.
    r->rax = mc_syscall(nr, r->rdi, r->rsi, r->rdx);
}

__attribute__((naked, used)) static void syscall_stub(void) {
    __asm__ volatile(
        "push %%r15\n push %%r14\n push %%r13\n push %%r12\n"
        "push %%r11\n push %%r10\n push %%r9\n push %%r8\n"
        "push %%rbp\n push %%rax\n push %%rbx\n push %%rcx\n"
        "push %%rdx\n push %%rsi\n push %%rdi\n"
        "mov %%rsp, %%rdi\n"
        "call syscall_dispatch_x86\n"
        "pop %%rdi\n pop %%rsi\n pop %%rdx\n"
        "pop %%rcx\n pop %%rbx\n pop %%rax\n pop %%rbp\n"
        "pop %%r8\n pop %%r9\n pop %%r10\n pop %%r11\n"
        "pop %%r12\n pop %%r13\n pop %%r14\n pop %%r15\n"
        "iretq\n"
        : : : "memory");
}

static void idt_install(void) {
    for (int i = 0; i < 256; i++) idt_set(i, unk_stub, 0);
    idt_set(0, fault_stub_0, 0);   idt_set(1, fault_stub_1, 0);   idt_set(2, fault_stub_2, 0);
    idt_set(3, fault_stub_3, 0);   idt_set(4, fault_stub_4, 0);   idt_set(5, fault_stub_5, 0);
    idt_set(6, fault_stub_6, 0);   idt_set(7, fault_stub_7, 0);   idt_set(8, fault_stub_8, 0);
    idt_set(9, fault_stub_9, 0);   idt_set(10, fault_stub_10, 0); idt_set(11, fault_stub_11, 0);
    idt_set(12, fault_stub_12, 0); idt_set(13, fault_stub_13, 0); idt_set(14, fault_stub_14, 0);
    idt_set(15, fault_stub_15, 0); idt_set(16, fault_stub_16, 0); idt_set(17, fault_stub_17, 0);
    idt_set(18, fault_stub_18, 0); idt_set(19, fault_stub_19, 0);
    idt_set(0x80, syscall_stub, 3);
    g_idtr.limit = (uint16_t)(sizeof(g_idt) - 1);
    g_idtr.base = (uint64_t)(uintptr_t)&g_idt[0];
    __asm__ volatile("lidt %0" : : "m"(g_idtr) : "memory");
}

// ========================= ring-3 entry (identical to M6 user_runtime.c) =========================
__attribute__((naked, used)) static void enter_user(uint64_t entry, uint64_t user_rsp) {
    __asm__ volatile(
        "mov %0, %%ax\n"
        "mov %%ax, %%ds\n"
        "mov %%ax, %%es\n"
        "mov %%ax, %%fs\n"
        "mov %%ax, %%gs\n"
        "push %1\n"
        "push %%rsi\n"
        "push $0x202\n"
        "push %2\n"
        "push %%rdi\n"
        "iretq\n"
        : : "i"(SEL_UDATA), "i"(SEL_UDATA), "i"(SEL_UCODE) : "rax", "memory");
}

// ---- backing store ----
// The agent's page tables + the per-page frames the loader allocates. QuickJS needs MiB: the
// 8 MiB malloc arena (host) + the engine text/rodata/data + the 512 KiB user stack + interior
// tables. 16 MiB, matching the riscv confined runtime. Lives in .bss under the low-1-GiB kernel
// identity window (mapped supervisor-only in the agent's CR3).
__attribute__((aligned(4096))) static uint8_t region[16u << 20];
__attribute__((aligned(16)))   static uint8_t kernel_trap_stack[16384]; // RSP0

void kmain(void) {
    serial_init();
    pic_mask_all(); // legacy PIC IRQs overlap exception vectors; mask them (agent uses polled I/O)
    puts_("x86-64 long mode: confined QuickJS agent boot OK\n");

    gdt_install();
    puts_("qjs: GDT+TSS installed (ring0/ring3 segments, TR loaded)\n");
    idt_install();
    puts_("qjs: IDT installed (#GP=13, #PF=14, syscall=0x80 DPL3)\n");

    g_tss.rsp0 = (uint64_t)(uintptr_t)(kernel_trap_stack + sizeof(kernel_trap_stack));
    g_tss.iomap_base = (uint16_t)sizeof(g_tss);

    // Register the MC syscall table (SYS_WRITE/READ/GETPID/SUBMIT/POLL) before any int 0x80.
    syscall_setup();

    // Build the agent's isolated space: load the QuickJS ELF + add the kernel supervisor window.
    uint64_t cr3 = 0;
    uint32_t ok = app_build_x86((uintptr_t)app_image, (uintptr_t)app_image_len,
                                (uintptr_t)region, (uintptr_t)sizeof(region), &cr3);
    if (!ok || cr3 == 0) {
        puts_(load_status_str(app_build_status_x86()));
        qemu_exit(1);
        halt_forever();
    }
    puts_("qjs: agent address space built, cr3="); puthex64(cr3); putc_('\n');

    // Confinement proof (M6 form): the kernel is mapped (so long mode survives the CR3 reload)
    // but is NOT user-accessible — a direct kernel touch from ring 3 would fault.
    if (app_kernel_not_user_x86((uintptr_t)KERNEL_VA))
        puts_("CONFINED: kernel mapped supervisor-only (no PTE_US) in agent space\n");
    else
        puts_("LEAK: kernel user-accessible in agent space\n");
    if (app_entry_is_user_x86())
        puts_("CONFINED: agent entry is ring-3 accessible\n");
    else
        puts_("LEAK: agent entry not user-accessible\n");

    uint64_t entry = app_entry_x86();
    puts_("qjs: entering confined QuickJS agent\n");

    // Activate the agent's CR3 (kernel stays mapped supervisor-only, so this code keeps running),
    // then iretq into ring 3 at the QuickJS entry. crt0_x86's _start sets RSP to __user_stack_top,
    // so the user_rsp passed here is overwritten — pass entry as a harmless placeholder.
    __asm__ volatile("mov %0, %%cr3" : : "r"(cr3) : "memory");
    enter_user(entry, entry);

    puts_("QJS-X86-BAD (enter_user returned)\n");
    qemu_exit(1);
    halt_forever();
}
