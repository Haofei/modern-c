// Boot entry for the integrated kernel (tests/qemu/kmain_demo.mc). The context-switch
// primitives, UART, mc_halt, and _start come from context_runtime.c; this supplies
// the physical region the kernel carves the heap (and process stacks) from, calls
// kmain, and reports the stage bitmask.
#include <stdint.h>
#include <stddef.h>

// The session-pool workload zeroes/copies aggregates, so the compiler emits these.
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

void putc_(char c);
void puts_(const char *s);
void mc_halt(void);

uint32_t kmain(uintptr_t region_base, uintptr_t region_len);

__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];

__attribute__((used)) void test_main(void) {
    puts_("\nkmain boot (integrated kernel)\n");
    uint32_t stages = kmain((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region));
    puts_("\nstages=0x");
    putc_("0123456789abcdef"[(stages >> 4) & 0xf]);
    putc_("0123456789abcdef"[stages & 0xf]);
    putc_('\n');
    if (stages == 0x3F) puts_("KERNEL-OK\n"); // 5 subsystems + the session-pool workload
    else puts_("KERNEL-INCOMPLETE\n");
    mc_halt();
}
