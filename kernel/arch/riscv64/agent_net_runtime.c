// Boot entry for the agent-OS network-model demo (tests/qemu/proc/agent_net_demo.mc). The
// UART, mc_halt, and _start come from context_runtime.c; this supplies the physical region the
// kernel carves the heap from, calls agent_net_main, and reports the stage bitmask. Prints
// AGENT-NET-OK when the full brokered-network agent story passed (heap+console up + the network
// story: brokered egress with a per-agent allowlist, a disallowed host blocked, budgeted + audited).
#include <stdint.h>
#include <stddef.h>

void putc_(char c);
void puts_(const char *s);
void mc_halt(void);

uint32_t agent_net_main(uintptr_t region_base, uintptr_t region_len);

__attribute__((aligned(4096))) static uint8_t heap_region[256 * 1024];

__attribute__((used)) void test_main(void) {
    puts_("\nagent-net boot (sandboxed agent making brokered network calls)\n");
    uint32_t stages = agent_net_main((uintptr_t)heap_region, (uintptr_t)sizeof(heap_region));
    puts_("\nstages=0x");
    putc_("0123456789abcdef"[(stages >> 4) & 0xf]);
    putc_("0123456789abcdef"[stages & 0xf]);
    putc_('\n');
    if (stages == 0x7) puts_("AGENT-NET-OK\n"); // heap + console up and the brokered-network agent story fully passed
    else puts_("AGENT-NET-INCOMPLETE\n");
    mc_halt();
}
