// SMP spinlock contention runtime: every hart runs the locked-increment worker;
// the boot hart waits for all to finish and reports the final shared counter. If
// the lock provides real mutual exclusion the counter equals harts * ITERS exactly.
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

#define NHARTS 2
#define HSTACK 4096
#define ITERS 2000
#define EXPECTED (NHARTS * ITERS)

#define UART ((volatile uint8_t *)0x10000000UL)
#define FINISHER ((volatile uint32_t *)0x00100000UL)

static void putc_(char c) { *UART = (uint8_t)c; }
static void puts_(const char *s) { for (; *s; ++s) putc_(*s); }
static void putdec(uint32_t v) {
    char buf[12]; int n = 0;
    if (v == 0) { putc_('0'); return; }
    while (v) { buf[n++] = (char)('0' + (v % 10)); v /= 10; }
    while (n) putc_(buf[--n]);
}

// MC entry points (tests/qemu/smp_lock_demo.mc).
void     lock_worker(void);
uint32_t lock_done_count(void);
uint32_t lock_counter(void);

__attribute__((aligned(16), used)) uint8_t hart_stacks[NHARTS][HSTACK];

__attribute__((used)) void hart_main(uint64_t hartid) {
    lock_worker(); // ITERS locked increments of the shared counter
    if (hartid == 0) {
        while (lock_done_count() < NHARTS) {} // wait for every hart to finish
        puts_("SMP-LOCK ");
        putdec(lock_counter());
        putc_('\n');
        if (lock_counter() == EXPECTED) puts_("LOCK-OK\n");
        *FINISHER = 0x5555;
    }
    for (;;) { __asm__ volatile("wfi"); }
}

__attribute__((naked, section(".text.start"))) void _start(void) {
    __asm__ volatile(
        "csrr a0, mhartid\n"
        "la   t0, hart_stacks\n"
        "li   t1, 4096\n"
        "addi t2, a0, 1\n"
        "mul  t2, t2, t1\n"
        "add  sp, t0, t2\n"
        "call hart_main\n"
        "1: wfi\n"
        "j 1b\n");
}
