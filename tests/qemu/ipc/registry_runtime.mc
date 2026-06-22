// Bare-metal riscv64 M-mode test entry for the name/registry server demo
// (tests/qemu/ipc/registry_demo.mc) — in PURE MC (no C). The all-MC replacement for
// kernel/arch/riscv64/registry_runtime.c.
//
// `_start` and `mc_halt` come from the shared M-mode bring-up runtime
// (kernel/arch/riscv64/context_runtime.c, linked beside this object); `_start`
// calls the `test_main` exported here. This unit supplies the physical region the
// kernel heap sub-allocates per-thread stacks from, runs the SAME existing MC demo
// (a service registered by key, looked up by name, round-trips 1234), and reports
// REGISTRY-OK on success — writing the bare 16550 UART directly.

import "tests/qemu/lib/test_report.mc";

// Defined in the shared M-mode bring-up runtime (context_runtime.c).
extern fn mc_halt() -> void;

// The registry demo (tests/qemu/ipc/registry_demo.mc): an echo service registers by
// key; the client looks it up by name (not pid) and round-trips a value, returning
// 1234 on success.
extern fn registry_demo(region_base: usize, region_len: usize) -> u32;

// 256 KiB physical region the kernel heap sub-allocates thread stacks from.
global g_heap_region: [262144]u8;

export fn test_main() -> void {
    uputs("registry booting\n");
    let r: u32 = registry_demo((&g_heap_region) as usize, 262144);
    if r == 1234 {
        uputs("REGISTRY-OK\n");
    } else {
        uputs("REGISTRY-FAIL\n");
    }
    mc_halt();
}
