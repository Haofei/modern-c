// Cooperative round-robin on x86-64, the arch port's proof of life: three threads, each on
// its own stack, take turns via mc_switch_context (real x86-64 register save/restore). main
// rotates through A,B,C three times, producing "ABCABCABC". Runs natively on an x86-64 host.
import "kernel/arch/x86_64/context.mc";

const NTHREAD: usize = 3;
const STACK_WORDS: usize = 1024; // 8 KiB stack per thread
const ROUNDS: usize = 3;

global g_main: Context;
global g_ctx: [NTHREAD]Context;
global g_stack: [NTHREAD][STACK_WORDS]u64;
global g_cur: usize;
global g_out: [16]u8;
global g_out_len: usize;

fn emit(c: u8) -> void {
    if g_out_len < 16 {
        g_out[g_out_len] = c;
        g_out_len = g_out_len + 1;
    }
}

// A running thread yields control back to main (which drives the round-robin).
fn yield_to_main() -> void {
    let me: usize = g_cur;
    mc_switch_context(&g_ctx[me], &g_main);
}

fn thread_a() -> void { while true { emit(0x41); yield_to_main(); } } // 'A'
fn thread_b() -> void { while true { emit(0x42); yield_to_main(); } } // 'B'
fn thread_c() -> void { while true { emit(0x43); yield_to_main(); } } // 'C'

fn stack_top(i: usize) -> usize {
    let p: *mut u64 = &g_stack[i][0];
    return (p as usize) + STACK_WORDS * 8; // stacks grow down from the top
}

export fn sched_x86_run() -> u32 {
    g_out_len = 0;
    mc_thread_init(&g_ctx[0], stack_top(0), thread_a);
    mc_thread_init(&g_ctx[1], stack_top(1), thread_b);
    mc_thread_init(&g_ctx[2], stack_top(2), thread_c);

    var round: usize = 0;
    while round < ROUNDS {
        var i: usize = 0;
        while i < NTHREAD {
            g_cur = i;
            mc_switch_context(&g_main, &g_ctx[i]); // run thread i until it yields back
            i = i + 1;
        }
        round = round + 1;
    }

    // expect "ABCABCABC"
    var pass: u32 = 1;
    if g_out_len != 9 { pass = 0; }
    var k: usize = 0;
    while k < 9 {
        let want: u8 = (0x41 + (k % 3)) as u8; // A,B,C repeating
        if g_out[k] != want { pass = 0; }
        k = k + 1;
    }
    return pass;
}
