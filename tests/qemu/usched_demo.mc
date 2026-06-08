// Userspace-set scheduling policy: a "scheduler server" assigns priorities; the kernel
// runs the highest-priority runnable process. Three workers are spawned in order A,B,C
// but given priorities C>B>A, so they run C,B,A — the order is policy-driven, not the
// kernel's built-in round-robin. Each worker records itself then parks (non-runnable).

import "kernel/core/process.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const STACK_SIZE: usize = 8192;
global g_procs: ProcTable;
global g_order: [4]u8;
global g_n: usize;

fn park_and_yield(tag: u8) -> void {
    g_order[g_n] = tag;
    g_n = g_n + 1;
    proc_park(&g_procs);          // make self non-runnable so it isn't re-picked
    proc_yield_priority(&g_procs); // hand off to the next-highest-priority worker
}

fn worker_a() -> void { park_and_yield(0x41); } // 'A'
fn worker_b() -> void { park_and_yield(0x42); } // 'B'
fn worker_c() -> void { park_and_yield(0x43); } // 'C'

fn alloc_stack(h: *mut Heap) -> usize {
    let base: PAddr = heap_alloc(h, STACK_SIZE, 16);
    return pa_value(base) + STACK_SIZE;
}

export fn usched_run(region_base: usize, region_len: usize) -> u32 {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    proc_table_init(&g_procs);
    g_n = 0;
    let a: u32 = proc_spawn(&g_procs, alloc_stack(&heap), worker_a);
    let b: u32 = proc_spawn(&g_procs, alloc_stack(&heap), worker_b);
    let c: u32 = proc_spawn(&g_procs, alloc_stack(&heap), worker_c);
    // the policy server's decision: C highest, then B, then A
    proc_set_priority(&g_procs, a, 1);
    proc_set_priority(&g_procs, b, 2);
    proc_set_priority(&g_procs, c, 3);

    proc_yield_priority(&g_procs); // run them in priority order, return when all parked

    // expect run order C, B, A
    if g_n != 3 {
        return 0;
    }
    if g_order[0] == 0x43 {
        if g_order[1] == 0x42 {
            if g_order[2] == 0x41 {
                return 1;
            }
        }
    }
    return 0;
}
