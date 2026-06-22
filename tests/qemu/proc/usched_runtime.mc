// Bare-metal riscv64 test entry for the userspace-set scheduling-policy demo
// (tests/qemu/proc/usched_demo.mc) — in PURE MC (no C). The all-MC replacement for
// kernel/arch/riscv64/usched_runtime.c: it supplies the physical region the kernel
// heap carves process stacks from, runs the demo, and reports the result.
//
// `_start`, the context-switch primitive, and `mc_halt` come from the shared M-mode
// bring-up runtime (kernel/arch/riscv64/context_runtime.c, linked beside this object).
//
// The demo imports kernel/core/process.mc (which pulls in console) and so DEFINES
// `console_putc`; to avoid a duplicate definition across the two linked objects, this
// unit does NOT import console.mc — it writes the bare 16550 UART directly.

import "tests/qemu/lib/test_report.mc";

extern fn mc_halt() -> void;

// The userspace-policy demo (tests/qemu/proc/usched_demo.mc): three workers spawned
// A,B,C but assigned priorities C>B>A run C,B,A by externally-set policy; returns 1
// on success.
extern fn usched_run(region_base: usize, region_len: usize) -> u32;

// 256 KiB physical region the kernel heap sub-allocates process stacks from.
global g_heap_region: [262144]u8;

export fn test_main() -> void {
    uputs("usched booting\n");
    if usched_run((&g_heap_region) as usize, 262144) == 1 {
        uputs("USCHED-OK\n");
    } else {
        uputs("USCHED-BAD\n");
    }
    mc_halt();
}
