// kernel/arch/x86_64/timer_runtime — the C `kmain` for the x86-64 Local-APIC TIMER proof
// (timer_x86_demo). This proves REAL, non-polled interrupt delivery on x86-64.
//
// In 64-bit long mode (reached from boot.S, which identity-maps the low 1 GiB with 2 MiB pages
// and runs us at 1 MiB):
//   1. bring up COM1;
//   2. mask BOTH legacy 8259 PICs (pic_mask_all) so the ONLY device that can deliver an
//      interrupt is the Local APIC — a delivered tick therefore PROVES the LAPIC path, not a
//      stray PIC IRQ;
//   3. install an IDT with exception stubs (#GP/#PF etc., for diagnostics) AND a timer gate at
//      vector 0x20 whose naked ISR saves ALL caller-saved registers (this is an ASYNCHRONOUS
//      interrupt that can preempt kmain at any instruction — unlike the synchronous fault stubs
//      which halt and never return, the timer ISR returns via iretq, so it MUST preserve every
//      register it or the C handler touches), bumps g_ticks, signals LAPIC EOI, and iretq;
//   4. map the LAPIC MMIO page (default base 0xFEE00000, in the 3-4 GiB PDPT slot which boot.S
//      does NOT cover) by installing a fresh 1 GiB PD identity-mapping that region as huge pages
//      and wiring it into boot.S's PDPT[3];
//   5. enable the LAPIC (SVR bit 8) + spurious vector 0xFF, program the LVT timer in PERIODIC
//      mode at vector 0x20, divide-by-16, with an initial count tuned for a few ticks/second;
//   6. `sti`, then spin `while (g_ticks < TARGET) hlt;` — `hlt` parks the CPU until the NEXT
//      interrupt wakes it. If interrupts are NOT being delivered the loop never progresses and
//      the bounded QEMU timeout fails the gate; we do NOT paper over no-delivery with a busy
//      poll. A delivered tick is the wake event.
//   7. print `X86-TIMER TICKS=<n>` and `X86-TIMER-OK` over COM1.
//
// The MC fixture (tests/x86/timer_x86_demo.mc) supplies the threshold (timer_target) and the
// final verdict (timer_ok), mirroring vm_runtime.c calling vm_x86_build — so an MC object links.
#include <stdint.h>

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

// Mask every legacy-PIC IRQ line. The BIOS leaves the 8259 master PIC mapped to vectors
// 0x08..0x0F. We rely SOLELY on the Local APIC for interrupt delivery; masking both PICs (OCW1 =
// 0xFF to the data ports) guarantees a delivered vector-0x20 interrupt came from the LAPIC timer.
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
static void putdec(uint32_t v) {
    char buf[12];
    int i = 0;
    if (v == 0) { putc_('0'); return; }
    while (v > 0) { buf[i++] = (char)('0' + (v % 10)); v /= 10; }
    while (i > 0) putc_(buf[--i]);
}
static void puthex64(uint64_t v) {
    putc_('0'); putc_('x');
    for (int i = 60; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 0xf]);
}

static void qemu_exit(uint8_t code) { outb(0xf4, code); }
static void halt_forever(void) { for (;;) __asm__ volatile("hlt"); }

// ---------------------------- Local APIC ----------------------------
#define LAPIC_BASE   0xFEE00000UL
#define LAPIC_SVR    0xF0    // Spurious Interrupt Vector Register
#define LAPIC_EOI    0xB0    // End-Of-Interrupt
#define LAPIC_LVT_TIMER 0x320
#define LAPIC_TIMER_DIV 0x3E0
#define LAPIC_TIMER_INIT 0x380
#define LAPIC_TIMER_CUR  0x390
#define TIMER_VECTOR 0x20

static inline void lapic_write(uint32_t off, uint32_t val) {
    *(volatile uint32_t *)(LAPIC_BASE + off) = val;
}
static inline uint32_t lapic_read(uint32_t off) {
    return *(volatile uint32_t *)(LAPIC_BASE + off);
}

static volatile uint32_t g_ticks = 0;

// ---------------------------- IDT ----------------------------
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

#define KCODE_SEL 0x08

static void idt_set(int vec, void (*handler)(void)) {
    uint64_t addr = (uint64_t)(uintptr_t)handler;
    g_idt[vec].off_lo = (uint16_t)(addr & 0xFFFF);
    g_idt[vec].sel = KCODE_SEL;
    g_idt[vec].ist = 0;
    g_idt[vec].type_attr = 0x8E; // present, DPL=0, 64-bit interrupt gate (clears IF on entry)
    g_idt[vec].off_mid = (uint16_t)((addr >> 16) & 0xFFFF);
    g_idt[vec].off_hi = (uint32_t)((addr >> 32) & 0xFFFFFFFF);
    g_idt[vec].zero = 0;
}

// Exception diagnostics: print a marker + faulting RIP/CR2 and halt, so a bug is DIAGNOSED rather
// than silently triple-faulting. on_fault never returns (we halt).
__attribute__((used)) static void on_fault(uint64_t *frame, uint64_t vec) {
    uint64_t cr2;
    __asm__ volatile("mov %%cr2, %0" : "=r"(cr2));
    puts_("\nX86-TIMER-BAD TRAP vec="); puthex64(vec);
    puts_(" cr2="); puthex64(cr2);
    puts_(" w0="); puthex64(frame[0]);
    puts_(" w1="); puthex64(frame[1]);
    puts_(" w2="); puthex64(frame[2]); putc_('\n');
    qemu_exit(1);
    halt_forever();
}
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

// Timer C handler: minimal, async-safe. Bump the tick counter and signal LAPIC EOI so the LAPIC
// will deliver the next periodic interrupt. (used) so it survives -O1 even though only asm calls it.
__attribute__((used)) static void timer_handler(void) {
    g_ticks++;
    lapic_write(LAPIC_EOI, 0);
}

// Timer ISR stub. This is an ASYNCHRONOUS interrupt: it can preempt kmain (or anything) at an
// arbitrary instruction, so it MUST preserve every caller-saved (System-V "scratch") register —
// rax,rcx,rdx,rsi,rdi,r8..r11 — around the `call`, because the C handler is free to clobber them
// and the interrupted code expects them intact. The interrupt gate (type 0xE) already cleared IF
// on entry, so we are not re-entered. Return with iretq (restores RIP/CS/RFLAGS/RSP/SS).
__attribute__((naked, used)) static void timer_stub(void) {
    __asm__ volatile(
        "push %%rax\n push %%rcx\n push %%rdx\n push %%rsi\n push %%rdi\n"
        "push %%r8\n push %%r9\n push %%r10\n push %%r11\n"
        "call timer_handler\n"
        "pop %%r11\n pop %%r10\n pop %%r9\n pop %%r8\n"
        "pop %%rdi\n pop %%rsi\n pop %%rdx\n pop %%rcx\n pop %%rax\n"
        "iretq\n"
        : : : "memory");
}

static void idt_install(void) {
    for (int i = 0; i < 256; i++) idt_set(i, unk_stub);
    idt_set(0, fault_stub_0);   idt_set(1, fault_stub_1);   idt_set(2, fault_stub_2);
    idt_set(3, fault_stub_3);   idt_set(4, fault_stub_4);   idt_set(5, fault_stub_5);
    idt_set(6, fault_stub_6);   idt_set(7, fault_stub_7);   idt_set(8, fault_stub_8);
    idt_set(9, fault_stub_9);   idt_set(10, fault_stub_10); idt_set(11, fault_stub_11);
    idt_set(12, fault_stub_12); idt_set(13, fault_stub_13); idt_set(14, fault_stub_14);
    idt_set(15, fault_stub_15); idt_set(16, fault_stub_16); idt_set(17, fault_stub_17);
    idt_set(18, fault_stub_18); idt_set(19, fault_stub_19);
    idt_set(TIMER_VECTOR, timer_stub);
    g_idtr.limit = (uint16_t)(sizeof(g_idt) - 1);
    g_idtr.base = (uint64_t)(uintptr_t)&g_idt[0];
    __asm__ volatile("lidt %0" : : "m"(g_idtr) : "memory");
}

// A fresh page directory identity-mapping the 3..4 GiB region with 2 MiB huge pages, so the LAPIC
// MMIO page (0xFEE00000) is readable/writable. Caching is left as default (write-back); QEMU's
// emulated LAPIC tolerates this for the demo, and the read/write path still exercises real MMIO.
// 4 KiB-aligned and under the identity-mapped low 1 GiB, so its physical == virtual address.
__attribute__((aligned(4096))) static uint64_t lapic_pd[512];

// boot.S maps PML4[0]->PDPT->PD over only the low 1 GiB (PDPT slot 0). The LAPIC at 0xFEE00000
// lives in PDPT slot 3 (0xFEE00000 >> 30 == 3), which is unmapped. Rather than depend on a
// non-exported boot.S symbol, walk the LIVE tables from CR3: PML4 and the PDPT it points to are
// both in the low-1-GiB identity map, so their physical addresses are directly addressable here.
static void map_lapic_mmio(void) {
    // Identity-map [3 GiB, 4 GiB) with 2 MiB huge pages: pd[i] = (3 GiB + i*2 MiB) | P|W|PS.
    for (uint64_t i = 0; i < 512; i++) {
        uint64_t pa = 0xC0000000UL + (i << 21);
        lapic_pd[i] = pa | 0x83; // P | W | PS(huge)
    }
    uint64_t cr3;
    __asm__ volatile("mov %%cr3, %0" : "=r"(cr3));
    volatile uint64_t *pml4 = (volatile uint64_t *)(cr3 & ~0xFFFUL);
    volatile uint64_t *live_pdpt = (volatile uint64_t *)(pml4[0] & 0x000FFFFFFFFFF000UL);
    // Wire the new PD into PDPT slot 3 (covers 0xC0000000..0xFFFFFFFF, containing 0xFEE00000).
    live_pdpt[3] = ((uint64_t)(uintptr_t)&lapic_pd[0]) | 0x3; // P | W
    // Flush the TLB so the new mapping takes effect (reload CR3).
    __asm__ volatile("mov %0, %%cr3" : : "r"(cr3) : "memory");
}

static void lapic_init_timer(void) {
    // Enable the LAPIC: SVR bit 8 (APIC software enable) | spurious vector 0xFF.
    lapic_write(LAPIC_SVR, (1u << 8) | 0xFF);
    // Divide configuration: 0x3 == divide by 16.
    lapic_write(LAPIC_TIMER_DIV, 0x3);
    // LVT timer: vector 0x20 | periodic mode (bit 17). Unmasked (bit 16 clear).
    lapic_write(LAPIC_LVT_TIMER, TIMER_VECTOR | (1u << 17));
    // Initial count: periodic reload value. Tuned so several ticks fire within the bounded spin.
    lapic_write(LAPIC_TIMER_INIT, 0x00100000);
}

// MC fixture: arch-neutral threshold + verdict (mirrors vm_runtime.c calling MC). timer_target()
// returns the required tick count; timer_ok(n) returns 1 iff n >= target.
extern uint32_t timer_target(void);
extern uint32_t timer_ok(uint32_t ticks);

void kmain(void) {
    serial_init();
    puts_("x86-64 long mode: LAPIC timer demo boot OK\n");

    pic_mask_all();
    puts_("timer: 8259 PICs masked (LAPIC is the only interrupt source)\n");

    idt_install();
    puts_("timer: IDT installed (faults + timer vec 0x20)\n");

    map_lapic_mmio();
    // Confirm the LAPIC MMIO page is reachable: read the (read-only) version register at 0x30.
    uint32_t ver = lapic_read(0x30);
    puts_("timer: LAPIC MMIO mapped, version reg="); puthex64(ver); putc_('\n');

    lapic_init_timer();
    puts_("timer: LAPIC enabled, periodic timer armed at vec 0x20\n");

    uint32_t target = timer_target();
    puts_("timer: target ticks="); putdec(target); putc_('\n');

    __asm__ volatile("sti");
    puts_("timer: interrupts enabled (sti); waiting on real LAPIC ticks...\n");

    // Park on hlt until each tick wakes us. If no interrupt is ever delivered the loop NEVER
    // progresses and the bounded QEMU timeout fails the gate — we do NOT fall back to a busy poll.
    while (g_ticks < target) {
        __asm__ volatile("hlt");
    }

    uint32_t n = g_ticks;
    puts_("X86-TIMER TICKS="); putdec(n); putc_('\n');

    if (timer_ok(n) == 1) {
        puts_("X86-TIMER-OK\n");
        qemu_exit(0);
    } else {
        puts_("X86-TIMER-BAD (verdict)\n");
        qemu_exit(1);
    }
    halt_forever();
}
