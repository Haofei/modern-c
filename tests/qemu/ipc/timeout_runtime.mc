// Bare-metal riscv64 M-mode test entry for the IPC timeout demo
// (tests/qemu/ipc/timeout_demo.mc) — in PURE MC (no C). The all-MC replacement for
// kernel/arch/riscv64/timeout_runtime.c.
//
// `_start` and `mc_halt` come from the shared M-mode bring-up runtime
// (kernel/arch/riscv64/context_runtime.c, linked beside this object); `_start`
// calls the `test_main` exported here. This unit supplies the physical region the
// kernel heap carves per-thread stacks from, runs the SAME existing MC demo, and
// reports TIMEOUT-OK when the bounded receive returns a timeout (1) instead of
// blocking forever — writing the bare 16550 UART directly.

import "tests/qemu/lib/test_report.mc";

// Defined in the shared M-mode bring-up runtime (context_runtime.c).
extern fn mc_halt() -> void;

// The timeout demo (tests/qemu/ipc/timeout_demo.mc): ipc_receive_timeout returns a
// timeout instead of blocking forever when no message arrives; returns 1 on success.
extern fn timeout_demo(region_base: usize, region_len: usize) -> u32;

// 256 KiB physical region the kernel heap sub-allocates thread stacks from.
global g_heap_region: [262144]u8;

export fn test_main() -> void {
    uputs("timeout booting\n");
    if timeout_demo((&g_heap_region) as usize, 262144) == 1 {
        uputs("TIMEOUT-OK\n");
    } else {
        uputs("TIMEOUT-FAIL\n");
    }
    mc_halt();
}
