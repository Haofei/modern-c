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

// net_broker now imports kernel/net/tcp_socket (the REAL transport used by the agent-net-REAL demo),
// which transitively pulls the virtio-net driver into EVERY net_broker consumer — including this
// MOCK demo. The mock path never touches the device (its endpoints are in-process fn pointers), but
// the driver code still references these std/dma + std/time platform primitives, so the symbols must
// resolve. They are DEAD in this image (never called on the mock path) — minimal stubs suffice.
uint64_t mc_read_ticks(void) { return 0; }
void mc_udelay(uint32_t us) { (void)us; }
uintptr_t mc_dma_alloc_base(uintptr_t len) { (void)len; return 0; }
void mc_dma_free_base(uintptr_t dev_addr, uintptr_t cpu_addr, uintptr_t len) { (void)dev_addr; (void)cpu_addr; (void)len; }
void mc_dma_clean_for_device_base(uintptr_t dev_addr, uintptr_t cpu_addr, uintptr_t len) { (void)dev_addr; (void)cpu_addr; (void)len; }
uintptr_t mc_dma_invalidate_for_cpu_base(uintptr_t dev_addr, uintptr_t len) { (void)len; return dev_addr; }

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
