// Bare-metal riscv64 runtime exercising the MC C-ABI allocator (user/libc/alloc.mc) the way C
// code (QuickJS) will: malloc/free/calloc/realloc through the standard prototypes. Verifies
// distinct non-overlapping allocations, write/read round-trips, reuse after free, calloc
// zeroing, and realloc content preservation, then reports on the UART.
#include <stdint.h>
#include <stddef.h>

#define UART ((volatile uint8_t *)0x10000000UL)
static void puts_(const char *s) {
    for (; *s; ++s) *UART = (uint8_t)*s;
}

#define FINISHER ((volatile uint32_t *)0x00100000UL)

// The MC allocator (object symbols: malloc/calloc/realloc/free).
extern void *malloc(size_t);
extern void *calloc(size_t, size_t);
extern void *realloc(void *, size_t);
extern void  free(void *);

static void fill(unsigned char *p, size_t n, unsigned char seed) {
    for (size_t i = 0; i < n; i++) p[i] = (unsigned char)(seed + i);
}
static int check(const unsigned char *p, size_t n, unsigned char seed) {
    for (size_t i = 0; i < n; i++)
        if (p[i] != (unsigned char)(seed + i)) return 0;
    return 1;
}

__attribute__((used)) void test_main(void) {
    puts_("alloc: exercising MC C-ABI allocator\n");
    int ok = 1;

    // Distinct, writable, non-overlapping allocations.
    unsigned char *a = (unsigned char *)malloc(100);
    unsigned char *b = (unsigned char *)malloc(200);
    if (!a || !b || a == b) ok = 0;
    if (ok) { fill(a, 100, 0x11); fill(b, 200, 0x22); }
    if (ok && (!check(a, 100, 0x11) || !check(b, 200, 0x22))) ok = 0; // no aliasing

    // Reuse after free: freeing a then allocating the same size should succeed and be writable.
    free(a);
    unsigned char *c = (unsigned char *)malloc(100);
    if (!c) ok = 0;
    if (ok) { fill(c, 100, 0x33); if (!check(c, 100, 0x33)) ok = 0; }
    if (ok && !check(b, 200, 0x22)) ok = 0; // b untouched by a's free + c's alloc

    // calloc zeroes.
    unsigned char *z = (unsigned char *)calloc(10, 8); // 80 bytes
    if (!z) ok = 0;
    if (ok) for (int i = 0; i < 80; i++) if (z[i] != 0) { ok = 0; break; }

    // realloc preserves existing content and grows.
    unsigned char *r = (unsigned char *)malloc(50);
    if (!r) ok = 0;
    if (ok) fill(r, 50, 0x44);
    unsigned char *r2 = (unsigned char *)realloc(r, 100);
    if (!r2) ok = 0;
    if (ok && !check(r2, 50, 0x44)) ok = 0; // first 50 bytes survive the grow

    // calloc overflow returns NULL (must not trap) — reachable from a huge JS typed-array length.
    if (calloc((size_t)-1, 2) != 0) ok = 0;
    if (calloc((size_t)1 << 40, (size_t)1 << 40) != 0) ok = 0;

    free(b);
    free(c);
    free(z);
    free(r2);

    if (ok) puts_("ALLOC-OK\n");
    else puts_("ALLOC-BAD\n");

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
