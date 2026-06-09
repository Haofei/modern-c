// A cooperative two-context ping-pong, demonstrating kernel context switching.
//
// `main` and one worker alternate by switching into each other. The worker's
// entry is an ordinary `fn() -> void` (a function pointer) — the context-switch
// primitive plus function pointers are all that's needed; no raw addresses here.

import "kernel/arch/riscv64/context.mc";
import "kernel/core/console.mc";

const ROUNDS: u32 = 3;

// The two switchable contexts. `main` is filled in on the first switch out of it;
// `worker` is primed by `mc_thread_init` before the first switch into it.
global g_main: Context = .{ .ra = 0, .sp = 0, .s0 = 0, .s1 = 0, .s2 = 0, .s3 = 0, .s4 = 0, .s5 = 0, .s6 = 0, .s7 = 0, .s8 = 0, .s9 = 0, .s10 = 0, .s11 = 0 };
global g_worker: Context = .{ .ra = 0, .sp = 0, .s0 = 0, .s1 = 0, .s2 = 0, .s3 = 0, .s4 = 0, .s5 = 0, .s6 = 0, .s7 = 0, .s8 = 0, .s9 = 0, .s10 = 0, .s11 = 0 };

fn worker_entry() -> void {
    var i: u32 = 0;
    while i < ROUNDS {
        console_putc('W');
        mc_switch_context(&g_worker, &g_main); // yield back to main
        i = i + 1;
    }
    // The loop is done, but a thread entry must never return (its `ra` is not a
    // valid return address); hand control back to main for good.
    mc_switch_context(&g_worker, &g_main);
}

export fn thread_demo(worker_stack_top: usize) -> u32 {
    mc_thread_init(&g_worker, worker_stack_top, worker_entry);
    var i: u32 = 0;
    while i < ROUNDS {
        console_putc('M');
        mc_switch_context(&g_main, &g_worker); // run the worker until it yields back
        i = i + 1;
    }
    return ROUNDS;
}
