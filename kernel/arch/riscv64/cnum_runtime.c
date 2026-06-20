// Bare-metal riscv64 runtime exercising the MC ctype + integer-parsing core (user/libc/cnum.mc)
// through the standard C prototypes, as QuickJS will. Linked standalone (no freestanding.c).
#include <stdint.h>
#include <stddef.h>

#define UART ((volatile uint8_t *)0x10000000UL)
static void puts_(const char *s) {
    for (; *s; ++s) *UART = (uint8_t)*s;
}
#define FINISHER ((volatile uint32_t *)0x00100000UL)

__attribute__((weak)) void mc_trap_IntegerOverflow(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_Bounds(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_DivideByZero(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_InvalidShift(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_InvalidRepresentation(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_Assert(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_NullUnwrap(void) { *FINISHER = 0x3333; for (;;) {} }
__attribute__((weak)) void mc_trap_Unreachable(void) { *FINISHER = 0x3333; for (;;) {} }

extern int isdigit(int), isalpha(int), isalnum(int), isspace(int), isxdigit(int);
extern int isupper(int), islower(int), isprint(int), ispunct(int);
extern int tolower(int), toupper(int), abs(int);
extern long      strtol(const char *, char **, int);
extern unsigned long strtoul(const char *, char **, int);
extern int       atoi(const char *);

__attribute__((used)) void test_main(void) {
    puts_("cnum: exercising MC ctype + integer parsing\n");
    int ok = 1;

    // ctype
    if (!isdigit('5') || isdigit('a')) ok = 0;
    if (!isalpha('a') || !isalpha('Z') || isalpha('5')) ok = 0;
    if (!isalnum('5') || !isalnum('q') || isalnum('!')) ok = 0;
    if (!isspace(' ') || !isspace('\t') || isspace('x')) ok = 0;
    if (!isxdigit('F') || !isxdigit('9') || isxdigit('g')) ok = 0;
    if (!isupper('A') || isupper('a')) ok = 0;
    if (!isprint(' ') || isprint('\n')) ok = 0;
    if (!ispunct('!') || ispunct('a')) ok = 0;
    if (toupper('a') != 'A' || toupper('Z') != 'Z') ok = 0;
    if (tolower('Z') != 'z' || tolower('a') != 'a') ok = 0;
    if (abs(-5) != 5 || abs(7) != 7) ok = 0;

    // strtol with endptr
    char *end;
    if (strtol("123", &end, 10) != 123 || *end != '\0') ok = 0;
    if (strtol("  -42xyz", &end, 10) != -42 || *end != 'x') ok = 0;
    if (strtol("0xFF", &end, 16) != 255 || *end != '\0') ok = 0;
    if (strtol("0x1A", &end, 0) != 26) ok = 0;
    if (strtol("777", &end, 8) != 511) ok = 0; // 0777 octal = 511
    if (strtol("0", &end, 10) != 0 || *end != '\0') ok = 0;
    if (atoi("789") != 789) ok = 0;

    // strtoul negative wraps modulo 2^64
    if (strtoul("-1", &end, 10) != (unsigned long)~0UL) ok = 0;
    if (strtoul("4294967296", &end, 10) != 4294967296UL) ok = 0;

    if (ok) puts_("CNUM-OK\n");
    else puts_("CNUM-BAD\n");

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
