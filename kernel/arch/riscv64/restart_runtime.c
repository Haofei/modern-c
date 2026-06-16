// Test entry for the reincarnation demo (tests/qemu/restart_demo.mc). The server
// crashes once ('X'); the supervisor restarts it ('R'); the system recovers.
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
void putc_(char c);
void puts_(const char *s);
void mc_halt(void);
uint32_t restart_demo(uintptr_t region_base, uintptr_t region_len);
__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];
__attribute__((used)) void test_main(void) {
    puts_("restart booting\n[");
    uint32_t restarts = restart_demo((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region));
    puts_("]\nrestarts=");
    putc_((char)('0' + restarts % 10));
    putc_('\n');
    if (restarts == 1) puts_("RESTART-OK\n");
    else puts_("RESTART-FAIL\n");
    mc_halt();
}
