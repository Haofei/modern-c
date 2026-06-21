// Bare-metal M-mode runtime for the D2.4 redzone + stack-canary demo.
//
// No paging is needed: we run in M-mode, hand the MC heap a real writable pool, and
// drive the demo entry points. The MC `unreachable` that the redzone/canary check
// raises on corruption lowers (C backend) to `__builtin_trap()` — a riscv illegal
// instruction. We install an M-mode trap vector that catches it, prints a "DETECTED"
// marker, and halts via the QEMU test finisher. So the trap is observable and proves
// the redzone/canary check actually fired on a real out-of-bounds write / smashed
// frame: the clean path returns normally and never reaches the trap vector, so it
// never prints DETECTED.
//
// Two scenarios, selected at compile time so each produces a clean transcript:
//   default        : clean alloc/use/free (prints D2.4-OK), then a REAL one-past-the-
//                     end write into the trailing redzone is caught on free -> DETECTED
//   CANARY_SCENARIO: clean alloc/use/free (prints D2.4-OK), then a smashed stack guard
//                     is caught by guard_check -> DETECTED
#include <stdint.h>
#include <stddef.h>

#define UART ((volatile uint8_t *)0x10000000UL)
#define FINISHER ((volatile uint32_t *)0x00100000UL)
static void putc_(char c) { *UART = (uint8_t)c; }
static void puts_(const char *s) { for (; *s; ++s) putc_(*s); }
static void halt(void) { *FINISHER = 0x5555; for (;;) {} }

// MC entry points.
uint32_t redzone_clean(uintptr_t region, uintptr_t len);
uint32_t redzone_overflow(uintptr_t region, uintptr_t len);
uint32_t canary_demo(void);

// A real, writable backing pool for the kernel heap.
__attribute__((aligned(64))) static uint8_t pool[64 * 1024];

// M-mode trap vector. Any trap here is the `__builtin_trap()` raised by the MC
// redzone/canary `unreachable` (an illegal instruction). Report it and halt — the
// observable proof that the corruption check fired.
__attribute__((used)) void on_trap(void) { puts_("DETECTED\n"); halt(); }

__attribute__((naked, aligned(4))) void trap_vector(void) {
    __asm__ volatile("call on_trap\n");
}

__attribute__((used)) void m_main(void) {
    // Route all M-mode traps (illegal instruction from __builtin_trap) to our vector.
    __asm__ volatile("csrw mtvec, %0\n" ::"r"((uintptr_t)&trap_vector) : "memory");

    puts_("redzone demo booting (M-mode)\n");

    // 1. Clean path: a redzoned alloc used in-bounds, checked and freed without a trap.
    uint32_t ok = redzone_clean((uintptr_t)pool, (uintptr_t)sizeof(pool));
    if (ok == 1u) {
        puts_("D2.4-OK\n"); // clean alloc/use/free with redzones intact
    } else {
        puts_("D2.4-BAD\n");
        halt();
    }

#ifdef CANARY_SCENARIO
    // 2a. Stack canary: smash a guard, the check must trap (-> DETECTED).
    puts_("canary: smashing guard...\n");
    canary_demo();
    puts_("CANARY-MISSED\n"); // only reached if the canary check FAILED to fire
#else
    // 2b. Heap redzone: a real one-past-the-end write, caught on free (-> DETECTED).
    puts_("overflow: writing past allocation...\n");
    redzone_overflow((uintptr_t)pool, (uintptr_t)sizeof(pool));
    puts_("OVERFLOW-MISSED\n"); // only reached if the redzone check FAILED to fire
#endif
    halt();
}

__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile(
        "la sp, _stack_top\n"
        "call m_main\n"
        "1: j 1b\n");
}
