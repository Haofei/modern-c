// Bare-metal riscv64 runtime exercising the MC mem/string core (user/libc/cstr.mc) through the
// standard C prototypes, as QuickJS will. Linked WITHOUT the shared freestanding.c (which also
// defines memcpy/memset/...) so the MC definitions are the only ones; the few trap stubs the
// MC checked-arithmetic references are provided here.
#include <stdint.h>
#include <stddef.h>

#define UART ((volatile uint8_t *)0x10000000UL)
static void puts_(const char *s) {
    for (; *s; ++s) *UART = (uint8_t)*s;
}
#define FINISHER ((volatile uint32_t *)0x00100000UL)

// Trap stubs for the MC checked-arithmetic edges (never hit by this test's in-range ops).
__attribute__((weak)) void mc_trap_IntegerOverflow(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_Bounds(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_DivideByZero(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_InvalidShift(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_InvalidRepresentation(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_Assert(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_NullUnwrap(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_Unreachable(void) { *FINISHER = 0x3333; for (;;) {} }

// The MC mem/string core (object symbols).
extern void  *memcpy(void *, const void *, size_t);
extern void  *memset(void *, int, size_t);
extern void  *memmove(void *, const void *, size_t);
extern int    memcmp(const void *, const void *, size_t);
extern void  *memchr(const void *, int, size_t);
extern size_t strlen(const char *);
extern int    strcmp(const char *, const char *);
extern int    strncmp(const char *, const char *, size_t);
extern char  *strchr(const char *, int);

__attribute__((used)) void test_main(void) {
    puts_("cstr: exercising MC mem/string core\n");
    int ok = 1;
    static unsigned char buf[64];
    static unsigned char buf2[64];

    // memset + memcmp
    memset(buf, 0xAB, 32);
    for (int i = 0; i < 32; i++) if (buf[i] != 0xAB) ok = 0;
    if (buf[32] != 0) { /* untouched tail (buf is zero-init bss) */ }

    // memcpy + memcmp equal/unequal
    memcpy(buf2, buf, 32);
    if (memcmp(buf, buf2, 32) != 0) ok = 0;
    buf2[10] = 0x00;
    if (memcmp(buf, buf2, 32) <= 0) ok = 0; // buf[10]=0xAB > buf2[10]=0x00

    // strlen / strcmp / strncmp
    const char *s1 = "hello";
    const char *s2 = "hello";
    const char *s3 = "help";
    if (strlen(s1) != 5) ok = 0;
    if (strlen("") != 0) ok = 0;
    if (strcmp(s1, s2) != 0) ok = 0;
    if (strcmp(s1, s3) >= 0) ok = 0;      // "hello" < "help" ('l' < 'p')
    if (strncmp(s1, s3, 3) != 0) ok = 0;  // "hel" == "hel"
    if (strncmp(s1, s3, 4) >= 0) ok = 0;

    // strchr / memchr
    if (strchr(s1, 'l') != s1 + 2) ok = 0;
    if (strchr(s1, 'z') != 0) ok = 0;
    if (strchr(s1, '\0') != s1 + 5) ok = 0; // matches the terminator
    if (memchr(s1, 'o', 5) != s1 + 4) ok = 0;
    if (memchr(s1, 'z', 5) != 0) ok = 0;

    // memmove with overlap (shift right by 2 within a buffer)
    static char mv[8];
    mv[0] = 'A'; mv[1] = 'B'; mv[2] = 'C'; mv[3] = 'D'; mv[4] = 0;
    memmove(mv + 2, mv, 4); // -> "ABABCD"... region [2..6) becomes A B C D
    if (!(mv[2] == 'A' && mv[3] == 'B' && mv[4] == 'C' && mv[5] == 'D')) ok = 0;

    if (ok) puts_("CSTR-OK\n");
    else puts_("CSTR-BAD\n");

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
