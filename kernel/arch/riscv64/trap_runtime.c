// Bare-metal riscv64 runtime for the trap/timer demo. Provides the M-mode trap
// vector (a naked asm stub that saves caller state, calls the MC `handle_trap`,
// restores, and `mret`s), the entry, and UART I/O. The typed kernel
// (`kernel_tick_demo`) installs this vector through the hart typestate, enables
// interrupts, and counts CLINT timer ticks.
#include <stdint.h>

#define UART ((volatile uint8_t *)0x10000000UL)
static void putc_(char c) { *UART = (uint8_t)c; }
static void puts_(const char *s) { for (; *s; ++s) putc_(*s); }
static void putdec(uint32_t v) {
    char b[12]; int n = 0;
    if (v == 0) { putc_('0'); return; }
    while (v) { b[n++] = (char)('0' + (v % 10)); v /= 10; }
    while (n--) putc_(b[n]);
}

#define FINISHER ((volatile uint32_t *)0x00100000UL)

// MC entry points (kernel/arch/riscv64/trap.mc).
void handle_trap(uint64_t mcause, uint64_t mepc);
uint32_t kernel_tick_demo(uintptr_t trap_vector, uint32_t target);

// M-mode trap vector: save caller-saved integer registers, dispatch to the MC
// handler with (mcause, mepc), restore, and return from the trap.
__attribute__((naked, aligned(4))) void trap_vector(void) {
    __asm__ volatile(
        "addi sp, sp, -128\n"
        "sd ra, 0(sp)\n"  "sd t0, 8(sp)\n"  "sd t1, 16(sp)\n" "sd t2, 24(sp)\n"
        "sd t3, 32(sp)\n" "sd t4, 40(sp)\n" "sd t5, 48(sp)\n" "sd t6, 56(sp)\n"
        "sd a0, 64(sp)\n" "sd a1, 72(sp)\n" "sd a2, 80(sp)\n" "sd a3, 88(sp)\n"
        "sd a4, 96(sp)\n" "sd a5, 104(sp)\n" "sd a6, 112(sp)\n" "sd a7, 120(sp)\n"
        "csrr a0, mcause\n"
        "csrr a1, mepc\n"
        "call handle_trap\n"
        "ld ra, 0(sp)\n"  "ld t0, 8(sp)\n"  "ld t1, 16(sp)\n" "ld t2, 24(sp)\n"
        "ld t3, 32(sp)\n" "ld t4, 40(sp)\n" "ld t5, 48(sp)\n" "ld t6, 56(sp)\n"
        "ld a0, 64(sp)\n" "ld a1, 72(sp)\n" "ld a2, 80(sp)\n" "ld a3, 88(sp)\n"
        "ld a4, 96(sp)\n" "ld a5, 104(sp)\n" "ld a6, 112(sp)\n" "ld a7, 120(sp)\n"
        "addi sp, sp, 128\n"
        "mret\n");
}

__attribute__((used)) void test_main(void) {
    puts_("MC typed kernel booting\n");
    uint32_t ticks = kernel_tick_demo((uintptr_t)&trap_vector, 3);
    puts_("TICKS "); putdec(ticks); putc_('\n');
    if (ticks >= 3) puts_("TIMER-OK\n");
    else puts_("TIMER-FAIL\n");
    *FINISHER = 0x5555;
    for (;;) {
    }
}

__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call test_main\n"
        "1: j 1b\n");
}
