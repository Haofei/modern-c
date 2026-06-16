// Bare-metal riscv64 runtime for the trap/timer demo. Provides the M-mode trap
// vector (a naked asm stub that saves caller state, calls the MC `handle_trap`,
// restores, and `mret`s), the entry, and UART I/O. The typed kernel
// (`kernel_tick_demo`) installs this vector through the hart typestate, enables
// interrupts, and counts CLINT timer ticks.
#include <stdint.h>
#include <stddef.h>

// Freestanding mem* for bare-metal link: heap/Process struct growth made the
// backend emit memset/memcpy for large aggregate init/copy (e.g. heap_new,
// process_demo). Verbatim from kmain_runtime.c; memmove added for safety.
void *memset(void *d, int c, size_t n) {
    uint8_t *p = (uint8_t *)d;
    for (size_t i = 0; i < n; ++i) p[i] = (uint8_t)c;
    return d;
}
void *memcpy(void *d, const void *s, size_t n) {
    uint8_t *dp = (uint8_t *)d; const uint8_t *sp = (const uint8_t *)s;
    for (size_t i = 0; i < n; ++i) dp[i] = sp[i];
    return d;
}
void *memmove(void *d, const void *s, size_t n) {
    uint8_t *dp = (uint8_t *)d; const uint8_t *sp = (const uint8_t *)s;
    if (dp < sp) { for (size_t i = 0; i < n; ++i) dp[i] = sp[i]; }
    else { for (size_t i = n; i > 0; --i) dp[i-1] = sp[i-1]; }
    return d;
}

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

// std/time platform primitives (CLINT mtime @ 10 MHz on QEMU virt).
#define CLINT_MTIME 0x0200BFF8UL
uint64_t mc_read_ticks(void) { return *(volatile uint64_t *)CLINT_MTIME; }
void mc_udelay(uint32_t us) {
    uint64_t target = *(volatile uint64_t *)CLINT_MTIME + (uint64_t)us * 10u;
    while (*(volatile uint64_t *)CLINT_MTIME < target) { }
}

// MC entry points (kernel/arch/riscv64/trap.mc).
void handle_trap(uint64_t mcause, uint64_t mepc, uint64_t mtval);
uint32_t kernel_tick_demo(uintptr_t trap_vector, uint32_t target);

// Platform primitive used by kernel/core/panic.mc: stop the machine. On QEMU virt
// that's the SiFive test finisher.
void mc_halt(void) {
    *FINISHER = 0x5555;
    for (;;) {
    }
}

// M-mode trap vector. A trap arrives at an arbitrary instruction boundary, so we
// save a full integer-register frame (every GPR that can hold live caller state:
// ra, t0-t6, a0-a7, s0-s11; sp is managed here, gp/tp are fixed), dispatch to the
// MC handler with (mcause, mepc), restore, and `mret`. Saving the callee-saved
// registers too is belt-and-suspenders over the C ABI, so the interrupted context
// is preserved regardless of what the handler does.
__attribute__((naked, aligned(4))) void trap_vector(void) {
    __asm__ volatile(
        "addi sp, sp, -256\n"
        "sd ra,  0(sp)\n"  "sd t0,  8(sp)\n"  "sd t1, 16(sp)\n"  "sd t2, 24(sp)\n"
        "sd t3, 32(sp)\n"  "sd t4, 40(sp)\n"  "sd t5, 48(sp)\n"  "sd t6, 56(sp)\n"
        "sd a0, 64(sp)\n"  "sd a1, 72(sp)\n"  "sd a2, 80(sp)\n"  "sd a3, 88(sp)\n"
        "sd a4, 96(sp)\n"  "sd a5,104(sp)\n"  "sd a6,112(sp)\n"  "sd a7,120(sp)\n"
        "sd s0,128(sp)\n"  "sd s1,136(sp)\n"  "sd s2,144(sp)\n"  "sd s3,152(sp)\n"
        "sd s4,160(sp)\n"  "sd s5,168(sp)\n"  "sd s6,176(sp)\n"  "sd s7,184(sp)\n"
        "sd s8,192(sp)\n"  "sd s9,200(sp)\n"  "sd s10,208(sp)\n" "sd s11,216(sp)\n"
        "csrr a0, mcause\n"
        "csrr a1, mepc\n"
        "csrr a2, mtval\n"
        "call handle_trap\n"
        "ld ra,  0(sp)\n"  "ld t0,  8(sp)\n"  "ld t1, 16(sp)\n"  "ld t2, 24(sp)\n"
        "ld t3, 32(sp)\n"  "ld t4, 40(sp)\n"  "ld t5, 48(sp)\n"  "ld t6, 56(sp)\n"
        "ld a0, 64(sp)\n"  "ld a1, 72(sp)\n"  "ld a2, 80(sp)\n"  "ld a3, 88(sp)\n"
        "ld a4, 96(sp)\n"  "ld a5,104(sp)\n"  "ld a6,112(sp)\n"  "ld a7,120(sp)\n"
        "ld s0,128(sp)\n"  "ld s1,136(sp)\n"  "ld s2,144(sp)\n"  "ld s3,152(sp)\n"
        "ld s4,160(sp)\n"  "ld s5,168(sp)\n"  "ld s6,176(sp)\n"  "ld s7,184(sp)\n"
        "ld s8,192(sp)\n"  "ld s9,200(sp)\n"  "ld s10,208(sp)\n" "ld s11,216(sp)\n"
        "addi sp, sp, 256\n"
        "mret\n");
}

__attribute__((used)) void test_main(void) {
    puts_("MC typed kernel booting\n");
    uint32_t ticks = kernel_tick_demo((uintptr_t)&trap_vector, 3);
    puts_("TICKS "); putdec(ticks); putc_('\n');
    if (ticks >= 3) puts_("TIMER-OK\n");
    else puts_("TIMER-FAIL\n");

    // Trigger an unexpected trap (M-mode ecall) to exercise the fail-closed panic
    // path: handle_trap should diagnose it (PANIC ...) and halt, not silently mret.
    __asm__ volatile("ecall");

    *FINISHER = 0x5555; // unreachable if the panic path halts as intended
    for (;;) {
    }
}

__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call test_main\n"
        "1: j 1b\n");
}
