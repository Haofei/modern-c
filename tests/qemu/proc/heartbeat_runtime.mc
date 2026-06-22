// Bare-metal riscv64 M-mode test entry for the heartbeat reincarnation demo
// (tests/qemu/proc/heartbeat_demo.mc) — in PURE MC (no C). The all-MC replacement
// for kernel/arch/riscv64/heartbeat_runtime.c.
//
// `_start` and `mc_halt` come from the shared M-mode bring-up runtime
// (kernel/arch/riscv64/context_runtime.c, linked beside this object); `_start`
// calls the `test_main` exported here. This unit supplies the physical region the
// kernel heap carves per-thread stacks from, runs the SAME existing MC demo, and
// reports HB-OK on success — writing the bare 16550 UART directly.

import "tests/qemu/lib/test_report.mc";

// Defined in the shared M-mode bring-up runtime (context_runtime.c).
extern fn mc_halt() -> void;

// The heartbeat demo (tests/qemu/proc/heartbeat_demo.mc): detects a missed
// heartbeat via timeout, restarts the worker, and returns 1 once the restart
// heartbeats healthy.
extern fn heartbeat_demo(region_base: usize, region_len: usize) -> u32;

// 256 KiB physical region the kernel heap sub-allocates thread stacks from.
global g_heap_region: [262144]u8;

export fn test_main() -> void {
    uputs("heartbeat booting\n");
    if heartbeat_demo((&g_heap_region) as usize, 262144) == 1 {
        uputs("HB-OK\n");
    } else {
        uputs("HB-FAIL\n");
    }
    mc_halt();
}
