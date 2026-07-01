// Scheduler pick-path microbenchmark (Phase 2.2 of docs/performance-refactor-plan.md).
// NOT an m0 gate — run via `zig build sched-bench`. It times the round-robin selection
// hot path (next_runnable) that proc_yield calls on every cooperative switch: spawn a
// full ProcTable of runnable processes, then drive the pick MANY times, rotating the
// "current" slot exactly as a real yield chain would, and report the average cycle cost
// per pick via the rdcycle CSR.
//
//   SCHED-CYCLES <n>       — average cycles per next_runnable() pick
//
// This is the before/after number the plan's "measure first" rule requires: run it once
// on the O(MAX_PROCS)-scan baseline and once on the O(1) run-queue implementation.
//
// No context switch is performed — only the *selection* is measured — so the spawned
// workers never actually run; their entry is a park loop that is never entered.

import "kernel/core/process.mc";
import "kernel/core/console.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const STACK_SIZE: usize = 8192;
const WORKERS: u32 = 6;       // spawn 6 workers (+ bootstrap = 7 runnable of MAX_PROCS=8)
const ITERS: u32 = 200000;    // pick iterations to average over

global g_procs: ProcTable;
global g_sink: u64 = 0;       // checksum sink: keeps the picked slots live (defeats DCE)

// A never-run park loop: the workers are spawned only to populate the run set; the bench
// measures selection, not execution, so no worker is ever switched to.
fn park() -> void {
    while true {
        proc_yield(&g_procs);
    }
}

fn alloc_stack(h: *mut Heap) -> usize {
    let base: PAddr = heap_alloc(h, STACK_SIZE, 16);
    return pa_value(base) + STACK_SIZE;
}

fn rdcycle() -> u64 {
    var c: u64 = 0;
    #[unsafe_contract(precise_asm)] {
        unsafe {
            asm precise volatile {
                "rdcycle %0"
                out("t0") c: u64
            }
        }
    }
    return c;
}

// Run the pick loop and return the average cycles per pick (integer). `cur` walks the run
// set exactly as a chain of round-robin yields would advance `t.current`, so every call
// exercises the "next runnable after `from`" scan/lookup for a different starting slot.
export fn sched_bench(region_base: usize, region_len: usize) -> u64 {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    proc_table_init(&g_procs);
    var w: u32 = 0;
    while w < WORKERS {
        proc_spawn(&g_procs, alloc_stack(&heap), park);
        w = w + 1;
    }
    // Make the run set SPARSE so the pick actually exercises the selection cost: block
    // the interior workers (slots 1..WORKERS-1), leaving only slot 0 (bootstrap) and the
    // last worker runnable with a long gap between them. The O(MAX_PROCS)-scan baseline
    // must walk every blocked slot to reach the runnable one; the O(1) run-queue jumps to
    // it directly — that gap is what the before/after number measures.
    var b: u32 = 1;
    while b < WORKERS {
        proc_block(&g_procs, b as usize, 0); // BLOCK_RECV: non-runnable, still live
        b = b + 1;
    }

    var acc: u64 = 0;
    var cur: usize = 0;
    // Warm-up (not timed): prime caches / branch predictors.
    var wi: u32 = 0;
    while wi < 1000 {
        switch next_runnable(&g_procs, cur) {
            ok(n) => { cur = n; acc = acc + (n as u64); }
            err(e) => { cur = 0; }
        }
        wi = wi + 1;
    }

    let c0: u64 = rdcycle();
    var i: u32 = 0;
    while i < ITERS {
        switch next_runnable(&g_procs, cur) {
            ok(n) => { cur = n; acc = acc + (n as u64); }
            err(e) => { cur = 0; }
        }
        i = i + 1;
    }
    let c1: u64 = rdcycle();

    g_sink = acc; // publish the checksum so the loop body cannot be optimized away
    return (c1 - c0) / (ITERS as u64);
}
