// kernel/arch/riscv64/platform.h — the QEMU `virt` platform primitives every
// standalone runtime needs: freestanding mem ops, the 16550 UART, the SiFive test
// finisher (mc_halt), and the CLINT time source (std/time externs). Runtimes that
// link context_runtime.c get UART + mem from there instead; this header is for the
// self-contained runtimes (paging / SMP / virtio / backtrace) that previously each
// re-declared all of this. Include once per such runtime.
#ifndef MC_PLATFORM_H
#define MC_PLATFORM_H
#include <stdint.h>
#include <stddef.h>

// Freestanding libc primitives the compiler emits for struct copies/zeroing.
static void *memset(void *d, int c, size_t n) {
    uint8_t *p = (uint8_t *)d;
    for (size_t i = 0; i < n; ++i) p[i] = (uint8_t)c;
    return d;
}
static void *memcpy(void *d, const void *s, size_t n) {
    uint8_t *dp = (uint8_t *)d; const uint8_t *sp = (const uint8_t *)s;
    for (size_t i = 0; i < n; ++i) dp[i] = sp[i];
    return d;
}

// 16550 UART @ 0x1000_0000, SiFive test finisher @ 0x0010_0000.
#define MC_UART ((volatile uint8_t *)0x10000000UL)
#define MC_FINISHER ((volatile uint32_t *)0x00100000UL)
static void putc_(char c) { *MC_UART = (uint8_t)c; }
static void puts_(const char *s) { for (; *s; ++s) putc_(*s); }
static void puthex(uint32_t v) {
    putc_('0'); putc_('x');
    for (int i = 28; i >= 0; i -= 4) putc_("0123456789abcdef"[(v >> i) & 0xf]);
}
static void putdec(uint32_t v) {
    char b[12]; int n = 0;
    if (v == 0) { putc_('0'); return; }
    while (v) { b[n++] = (char)('0' + v % 10); v /= 10; }
    while (n) putc_(b[--n]);
}
static void mc_halt(void) { *MC_FINISHER = 0x5555; for (;;) {} }

// std/time externs: CLINT mtime @ 0x0200_BFF8 (10 MHz on QEMU virt).
#define MC_CLINT_MTIME 0x0200BFF8UL
uint64_t mc_read_ticks(void) { return *(volatile uint64_t *)MC_CLINT_MTIME; }
void mc_udelay(uint32_t us) {
    uint64_t t = mc_read_ticks() + (uint64_t)us * 10u;
    while (mc_read_ticks() < t) {}
}

#endif // MC_PLATFORM_H
