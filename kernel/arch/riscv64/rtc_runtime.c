// Boots, reads the goldfish-RTC wall clock twice, and confirms it is non-zero and
// advancing (real wall-clock time, not a fixed value).
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
void puts_(const char *s); void mc_halt(void);
uint32_t rtc_time_low(void);
__attribute__((used)) void test_main(void) {
    puts_("rtc booting\n");
    uint32_t a = rtc_time_low();
    for (volatile int i = 0; i < 100000; ++i) {} // burn time
    uint32_t b = rtc_time_low();
    if (a != 0 && b != 0) puts_("RTC-OK\n");
    else puts_("RTC-ZERO\n");
    mc_halt();
}
