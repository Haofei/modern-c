// Boot entry for the end-to-end agent-on-OS demo (tests/qemu/proc/agent_e2e_demo.mc). The
// UART, mc_halt, and _start come from context_runtime.c; this supplies the physical region the
// kernel carves the heap from, calls agent_e2e_main, and reports the stage bitmask. Prints
// AGENT-E2E-OK when the full sandboxed-agent story passed (heap+console up + e2e story).
#include <stdint.h>
#include <stddef.h>

// The process table copies aggregates, so the compiler may emit these.
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

uint32_t agent_e2e_main(uintptr_t region_base, uintptr_t region_len);

__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];

__attribute__((used)) void test_main(void) {
    puts_("\nagent-e2e boot (sandboxed agent on the kernel)\n");
    uint32_t stages = agent_e2e_main((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region));
    puts_("\nstages=0x");
    putc_("0123456789abcdef"[(stages >> 4) & 0xf]);
    putc_("0123456789abcdef"[stages & 0xf]);
    putc_('\n');
    if (stages == 0x7) puts_("AGENT-E2E-OK\n"); // heap + console up and the e2e agent story fully passed
    else puts_("AGENT-E2E-INCOMPLETE\n");
    mc_halt();
}
