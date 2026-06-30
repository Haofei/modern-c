// Boot entry for the agent-OS network-model demo (tests/qemu/proc/agent_net_demo.mc), in PURE MC
// (the all-MC replacement for agent_net_runtime.c). putc_/puts_/mc_halt come from the shared M-mode
// bring-up (context_runtime.mc); this supplies the physical region the kernel carves the heap from,
// calls agent_net_main, and reports the stage bitmask. Prints AGENT-NET-OK when the full brokered-
// network agent story passed (heap+console up + the network story: brokered egress with a per-agent
// allowlist, a disallowed host blocked, budgeted + audited).

const RT_PAGE: usize = 4096;
const RT_HEAP_LEN: usize = 262144; // 256 KiB usable

// From the shared M-mode bring-up runtime (context_runtime.mc).
extern fn putc_(c: u8) -> void;
extern fn puts_(s: *const u8) -> void;
extern fn mc_halt() -> void;

// The MC agent-net demo (tests/qemu/proc/agent_net_demo.mc).
extern fn agent_net_main(region_base: usize, region_len: usize) -> u32;

// net_broker imports kernel/net/tcp_socket (the REAL transport used by the agent-net-REAL demo),
// which transitively pulls the virtio-net driver into EVERY net_broker consumer — including this
// MOCK demo. The mock path never touches the device (its endpoints are in-process fn pointers), but
// the driver code still references these std/dma + std/time platform primitives, so the symbols must
// resolve. They are DEAD in this image (never called on the mock path) — minimal stubs suffice.
export fn mc_read_ticks() -> u64 { return 0; }
export fn mc_udelay(us: u32) -> void {}
export fn mc_dma_alloc_base(_len: usize) -> usize { return 0; }
export fn mc_dma_alloc_base_try(_len: usize) -> usize { return 0; } // dead stub: never called on the mock path
export fn mc_dma_free_base(_dev_addr: usize, _cpu_addr: usize, _len: usize) -> void {}
export fn mc_dma_clean_for_device_base(_dev_addr: usize, _cpu_addr: usize, _len: usize) -> void {}
export fn mc_dma_invalidate_for_cpu_base(dev_addr: usize, _len: usize) -> usize { return dev_addr; }

// Page-aligned heap region: over-allocated by a page so the base can be rounded up to a 4 KiB
// boundary at runtime (MC has no align attribute). 262144 usable + one page of slack.
global g_heap_region: [266240]u8;

// Round a base address up to the next 4 KiB page boundary.
fn page_align(base: usize) -> usize {
    return (base + (RT_PAGE - 1)) & ~(RT_PAGE - 1);
}

// ASCII hex digit for the low nibble of `v`.
fn hex_digit(v: u32) -> u8 {
    let n: u32 = v & 0xf;
    if n < 10 {
        return (48 + n) as u8; // '0'
    }
    return (87 + n) as u8; // 'a' - 10
}

export fn test_main() -> void {
    puts_("\nagent-net boot (sandboxed agent making brokered network calls)\n");
    let region: usize = page_align((&g_heap_region) as usize);
    let stages: u32 = agent_net_main(region, RT_HEAP_LEN);
    puts_("\nstages=0x");
    putc_(hex_digit(stages >> 4));
    putc_(hex_digit(stages));
    putc_(10); // '\n'
    if stages == 0x7 {
        // heap + console up and the brokered-network agent story fully passed
        puts_("AGENT-NET-OK\n");
    } else {
        puts_("AGENT-NET-INCOMPLETE\n");
    }
    mc_halt();
}
