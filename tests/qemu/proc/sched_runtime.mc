// Bare-metal riscv64 test entry for the round-robin scheduler demo
// (tests/qemu/proc/sched_demo.mc) — in PURE MC (no C). The all-MC replacement for
// kernel/arch/riscv64/sched_runtime.c: it supplies the physical region the kernel
// heap carves thread stacks from, runs the demo, and reports the round count.
//
// `_start`, the context-switch primitive, and `mc_halt` come from the shared M-mode
// bring-up runtime (kernel/arch/riscv64/context_runtime.c, linked beside this object).
// This unit declares `mc_halt` `extern fn` and drives the demo exactly as the C did.
//
// The scheduler demo imports kernel/core/console.mc and so DEFINES `console_putc` in
// its object; to avoid a duplicate definition across the two linked objects, this unit
// does NOT import console.mc — it writes the bare 16550 UART directly for diagnostics.

import "tests/qemu/lib/test_report.mc";

// Defined in the shared M-mode bring-up runtime (context_runtime.c).
extern fn mc_halt() -> void;

// The scheduler demo (tests/qemu/proc/sched_demo.mc): a three-thread cooperative
// round-robin over per-thread stacks carved from the kernel heap; returns the round
// count (3) after main -> A -> B -> C rotations print "ABCABCABC".
extern fn sched_demo(region_base: usize, region_len: usize) -> u32;

// 256 KiB physical region the kernel heap sub-allocates thread stacks from.
global g_heap_region: [262144]u8;

export fn test_main() -> void {
    uputs("scheduler booting\n");
    let rounds: u32 = sched_demo((&g_heap_region) as usize, 262144);
    uputs("\nSCHED-OK ");
    uputc((48 + (rounds % 10)) as u8);
    uputc(10); // '\n'
    mc_halt();
}
