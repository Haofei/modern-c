// Bare-metal riscv64 runtime exercising the MC printf family (user/libc/stdio.mc). Provides the
// mc_console_write hook (-> UART) the formatter streams through, then checks snprintf output
// against expected strings across the integer/string/char/pointer specifiers. Linked standalone.
#include <stdint.h>
#include <stddef.h>

#define UART ((volatile uint8_t *)0x10000000UL)
static void puts_(const char *s) {
    for (; *s; ++s) *UART = (uint8_t)*s;
}
#define FINISHER ((volatile uint32_t *)0x00100000UL)

// The console hook the MC formatter calls (stdio.mc: extern fn mc_console_write(buf, len)).
void mc_console_write(uintptr_t buf, uintptr_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    for (uintptr_t i = 0; i < len; i++) *UART = p[i];
}

__attribute__((weak)) void mc_trap_IntegerOverflow(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_Bounds(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_DivideByZero(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_InvalidShift(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_InvalidRepresentation(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_Assert(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_NullUnwrap(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_Unreachable(void) { *FINISHER = 0x3333; for (;;) {} }

extern int snprintf(char *, size_t, const char *, ...);
extern int printf(const char *, ...);

static int streq(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}

static char buf[128];
static int n_fail = 0;

#define EXPECT(fmt_call, want)                       \
    do {                                             \
        fmt_call;                                    \
        if (!streq(buf, want)) {                     \
            n_fail++;                                 \
            puts_("  MISMATCH: got '"); puts_(buf);  \
            puts_("' want '"); puts_(want); puts_("'\n"); \
        }                                            \
    } while (0)

__attribute__((used)) void test_main(void) {
    puts_("stdio: exercising MC printf family\n");

    EXPECT(snprintf(buf, sizeof buf, "%d", 42), "42");
    EXPECT(snprintf(buf, sizeof buf, "%d", -7), "-7");
    EXPECT(snprintf(buf, sizeof buf, "%05d", 42), "00042");
    EXPECT(snprintf(buf, sizeof buf, "%5d", 42), "   42");
    EXPECT(snprintf(buf, sizeof buf, "%-5d|", 42), "42   |");
    EXPECT(snprintf(buf, sizeof buf, "%+d", 42), "+42");
    EXPECT(snprintf(buf, sizeof buf, "%x", 255), "ff");
    EXPECT(snprintf(buf, sizeof buf, "%#x", 255), "0xff");
    EXPECT(snprintf(buf, sizeof buf, "%X", 255), "FF");
    EXPECT(snprintf(buf, sizeof buf, "%o", 8), "10");
    EXPECT(snprintf(buf, sizeof buf, "%u", 100u), "100");
    EXPECT(snprintf(buf, sizeof buf, "%c", 'A'), "A");
    EXPECT(snprintf(buf, sizeof buf, "%s", "hi"), "hi");
    EXPECT(snprintf(buf, sizeof buf, "%.3s", "hello"), "hel");
    EXPECT(snprintf(buf, sizeof buf, "%10s", "hi"), "        hi");
    EXPECT(snprintf(buf, sizeof buf, "%-10s|", "hi"), "hi        |");
    EXPECT(snprintf(buf, sizeof buf, "%%"), "%");
    EXPECT(snprintf(buf, sizeof buf, "%lld", 10000000000LL), "10000000000");
    EXPECT(snprintf(buf, sizeof buf, "%llx", 0xDEADBEEFULL), "deadbeef");
    EXPECT(snprintf(buf, sizeof buf, "%zu", (size_t)4096), "4096");
    EXPECT(snprintf(buf, sizeof buf, "x=%d,s=%s,h=%#x", 5, "ok", 16), "x=5,s=ok,h=0x10");
    EXPECT(snprintf(buf, sizeof buf, "%s", (char *)0), "(null)");
    EXPECT(snprintf(buf, sizeof buf, "%.*d", 4, 7), "0007");
    EXPECT(snprintf(buf, sizeof buf, "%*d", 6, 7), "     7");

    // truncation: C99 return is the would-be length; buffer is bounded + NUL-terminated.
    char small[4];
    int wid = snprintf(small, sizeof small, "%d", 123456);
    if (wid != 6) n_fail++;            // would have written 6 chars
    if (!streq(small, "123")) n_fail++; // but only 3 fit (+ NUL)

    if (n_fail == 0) {
        printf("printf-to-console works: %d+%d=%d\n", 2, 3, 5); // also exercise the console sink
        puts_("STDIO-OK\n");
    } else {
        puts_("STDIO-BAD\n");
    }

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
