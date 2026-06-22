// Bare-metal riscv64 M-mode test entry for the signal delivery demo
// (tests/qemu/ipc/signal_demo.mc) — in PURE MC (no C). The all-MC replacement for
// kernel/arch/riscv64/signal_runtime.c.
//
// `_start` and `mc_halt` come from the shared M-mode bring-up runtime
// (kernel/arch/riscv64/context_runtime.c, linked beside this object); `_start`
// calls the `test_main` exported here. This unit supplies the physical region the
// kernel heap carves per-thread stacks from, runs the SAME existing MC demo, and
// reports SIGNAL-OK when the demo returns 5 — writing the bare 16550 UART directly.

import "tests/qemu/lib/test_report.mc";

// Defined in the shared M-mode bring-up runtime (context_runtime.c).
extern fn mc_halt() -> void;

// The signal demo (tests/qemu/ipc/signal_demo.mc): one process delivers SIG_USR to
// another, which polls pending and takes it; returns 5 on success.
extern fn signal_demo(region_base: usize, region_len: usize) -> u32;

// 256 KiB physical region the kernel heap sub-allocates thread stacks from.
global g_heap_region: [262144]u8;

export fn test_main() -> void {
    uputs("signal booting\n");
    let s: u32 = signal_demo((&g_heap_region) as usize, 262144);
    if s == 5 {
        uputs("SIGNAL-OK\n");
    } else {
        uputs("SIGNAL-FAIL\n");
    }
    mc_halt();
}
