// Test entry for the driver-framework demo (tests/qemu/driver_demo.mc). UART,
// mc_halt, and _start come from context_runtime.c; the demo writes "DRV" to the
// console through the registered char-device driver.
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

uint32_t driver_demo(void);

__attribute__((used)) void test_main(void) {
    puts_("driver booting\n");
    uint32_t id = driver_demo(); // writes "DRV" through the registered driver
    puts_("\nDRIVER-OK ");
    putc_((char)('0' + (id % 10)));
    putc_('\n');
    mc_halt();
}
