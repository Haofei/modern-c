// Bare-metal riscv64 test entry for the process-lifecycle demo
// (tests/qemu/proc/process_demo.mc) — in PURE MC (no C). The all-MC replacement for
// kernel/arch/riscv64/process_runtime.c: it supplies the physical region the kernel
// heap carves process stacks from, runs the demo, and reports the reap count.
//
// `_start`, the context-switch primitive, and `mc_halt` come from the shared M-mode
// bring-up runtime (kernel/arch/riscv64/context_runtime.c, linked beside this object).
//
// The demo imports kernel/core/console.mc and so DEFINES `console_putc`; to avoid a
// duplicate definition across the two linked objects, this unit does NOT import
// console.mc — it writes the bare 16550 UART directly for diagnostics.

import "tests/qemu/lib/test_report.mc";

extern fn mc_halt() -> void;

// The process demo (tests/qemu/proc/process_demo.mc): the bootstrap spawns three
// processes (print A,B,C, exit with codes 1,2,3), yields once to run them, then reaps
// each (printing 1,2,3) — "ABC123"; returns the number reaped (3).
extern fn process_demo(region_base: usize, region_len: usize) -> u32;

// 256 KiB physical region the kernel heap sub-allocates process stacks from.
global g_heap_region: [262144]u8;

export fn test_main() -> void {
    uputs("process booting\n");
    let sum: u32 = process_demo((&g_heap_region) as usize, 262144);
    uputs("\nPROC-OK ");
    uputc((48 + (sum % 10)) as u8);
    uputc(10); // '\n'
    mc_halt();
}
