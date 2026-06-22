// Bare-metal riscv64 M-mode test entry for the cooperative ping-pong demo
// (tests/qemu/proc/thread_demo.mc) — in PURE MC (no C). The all-MC replacement for
// kernel/arch/riscv64/thread_runtime.c.
//
// `_start`, the context-switch primitive (mc_switch_context / mc_thread_init), and
// `mc_halt` come from the shared M-mode bring-up runtime
// (kernel/arch/riscv64/context_runtime.c, linked beside this object); `_start`
// calls the `test_main` exported here. This unit supplies the single worker stack
// and runs the SAME existing MC demo, reporting THREADS-OK + the round count.
//
// The thread demo imports kernel/core/console.mc and DEFINES `console_putc` (it
// writes 'M'/'W' as the two contexts interleave); to avoid a duplicate console
// definition across the two linked objects this unit does NOT import console.mc —
// it writes the bare 16550 UART directly for its own diagnostics.

import "tests/qemu/lib/test_report.mc";

// Defined in the shared M-mode bring-up runtime (context_runtime.c).
extern fn mc_halt() -> void;

// The thread demo (tests/qemu/proc/thread_demo.mc): a single-worker cooperative
// ping-pong; returns the number of completed rounds.
extern fn thread_demo(worker_stack_top: usize) -> u32;

// One worker stack for the single-worker ping-pong (8 KiB).
global g_worker_stack: [8192]u8;

export fn test_main() -> void {
    uputs("threads booting\n");
    // Stack top = end of the array, rounded down to a 16-byte boundary (the RISC-V
    // ABI requires sp to be 16-aligned; the array base may not be).
    let top: usize = (((&g_worker_stack) as usize) + 8192) & ~(15 as usize);
    let rounds: u32 = thread_demo(top);
    uputs("\nTHREADS-OK ");
    uputc((48 + (rounds % 10)) as u8); // '0' + (rounds % 10)
    uputc(10); // '\n'
    mc_halt();
}
