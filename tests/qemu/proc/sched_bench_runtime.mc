// Bare-metal riscv64 test entry for the scheduler pick-path microbenchmark
// (tests/qemu/proc/sched_bench_demo.mc). Supplies the physical region the kernel heap
// carves worker stacks from, runs the bench, and reports the average cycles per pick.
//
// `_start`, mc_thread_init, the context-switch primitive, and `mc_halt` come from the
// shared M-mode bring-up runtime (context_runtime.mc, linked beside this object). Like
// the other proc runtimes this unit does NOT import console.mc (the demo defines
// console_putc); it prints over the bare 16550 UART via test_report.

import "tests/qemu/lib/test_report.mc";
import "std/fmt/fmt_sink.mc";

extern fn mc_halt() -> void;

// The bench (tests/qemu/proc/sched_bench_demo.mc): spawns a full run set and times the
// next_runnable() round-robin pick, returning the average cycles per pick.
extern fn sched_bench(region_base: usize, region_len: usize) -> u64;

// 512 KiB physical region the kernel heap sub-allocates worker stacks from.
global g_heap_region: [524288]u8;

export fn test_main() -> void {
    uputs("sched-bench booting\n");
    let cyc: u64 = sched_bench((&g_heap_region) as usize, 524288);
    uputs("SCHED-CYCLES ");
    fmt_put_dec(uputc, cyc);
    uputc(10); // '\n'
    uputs("SCHED-BENCH-DONE\n");
    mc_halt();
}
