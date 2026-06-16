// Test entry for the cooperative ping-pong demo (tests/qemu/thread_demo.mc). The
// context-switch primitive + bring-up live in context_runtime.c.
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

// One worker stack for the single-worker ping-pong. The scheduler demo allocates
// per-thread stacks from the kernel heap instead.
__attribute__((aligned(16))) static uint8_t worker_stack[8192];

uint32_t thread_demo(uintptr_t worker_stack_top);

__attribute__((used)) void test_main(void) {
    puts_("threads booting\n");
    uint32_t rounds = thread_demo((uintptr_t)(worker_stack + sizeof(worker_stack)));
    puts_("\nTHREADS-OK ");
    putc_((char)('0' + (rounds % 10)));
    putc_('\n');
    mc_halt();
}
