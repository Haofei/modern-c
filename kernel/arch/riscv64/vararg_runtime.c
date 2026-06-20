// Bare-metal riscv64 runtime for the variadic-function demo. Calls the C-ABI variadic MC
// function `sum_args` (tests/qemu/lang/vararg_demo.mc) with several argument counts — exactly
// as C (QuickJS) will call our printf-family shims — verifies the sums, and reports on the UART.
#include <stdint.h>

#define UART ((volatile uint8_t *)0x10000000UL)
static void putc_(char c) { *UART = (uint8_t)c; }
static void puts_(const char *s) {
    for (; *s; ++s) putc_(*s);
}

#define FINISHER ((volatile uint32_t *)0x00100000UL)

// The MC variadic function under test.
extern int64_t sum_args(int32_t count, ...);

__attribute__((used)) void test_main(void) {
    puts_("vararg: calling C-ABI variadic MC fn\n");

    int ok = 1;
    // 10 + 20 + 30 = 60
    if (sum_args(3, (int64_t)10, (int64_t)20, (int64_t)30) != 60) ok = 0;
    // 1 + 2 + 3 + 4 + 5 = 15 (more varargs than fit in the arg registers exercises the
    // stack-spill portion of the cursor)
    if (sum_args(5, (int64_t)1, (int64_t)2, (int64_t)3, (int64_t)4, (int64_t)5) != 15) ok = 0;
    // 9 trailing args: forces stack-passed varargs on the lp64 ABI (8 arg regs, count is a0).
    if (sum_args(9, (int64_t)1, (int64_t)2, (int64_t)3, (int64_t)4, (int64_t)5,
                 (int64_t)6, (int64_t)7, (int64_t)8, (int64_t)9) != 45) ok = 0;
    // Zero varargs: the cursor is started and ended without a read.
    if (sum_args(0) != 0) ok = 0;
    // A negative-summing case to confirm signed i64 slots round-trip.
    if (sum_args(2, (int64_t)-100, (int64_t)40) != -60) ok = 0;

    if (ok) puts_("VARARG-OK\n");
    else puts_("VARARG-BAD\n");

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
