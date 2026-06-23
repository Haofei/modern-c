// async/await roadmap Phase B gate: request-id-keyed PARK/WAKE completion via
// kernel/lib/async.mc, exercised by two cooperative processes under the real scheduler.
//
// The `waiter` submits two in-flight requests and awaits them; `async_await` PARKS the task
// (proc_park + yield) instead of busy-spinning. The `completer` then completes both — OUT OF
// ORDER, and one of them BEFORE it is awaited — waking the parked waiter. The console trace
// `W C R` proves the sequence: W (waiter parked, yielding), C (completer ran because the
// waiter actually gave up the CPU), R (waiter resumed after being woken). Result 42 (= 22+20)
// proves both completions reached the waiter: one via park->wake, one already-ready (no park).

import "kernel/lib/async.mc";
import "kernel/core/process.mc";
import "kernel/arch/riscv64/idle.mc";
import "kernel/core/console.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const STACK_SIZE: usize = 8192;

global g_procs: ProcTable;
global g_broker: AsyncBroker;
global g_result: i32;
global g_id_a: u64;
global g_id_b: u64;

// Submit two requests, then await both. The first await PARKS (completer hasn't run yet);
// the second finds its request already completed (the completer ran while we were parked).
fn waiter() -> void {
    g_id_a = async_submit(&g_broker);
    g_id_b = async_submit(&g_broker);
    console_putc('W');
    let ra: i32 = async_await(&g_broker, &g_procs, g_id_a);   // parks until woken
    let rb: i32 = async_await(&g_broker, &g_procs, g_id_b);   // already ready -> no park
    g_result = ra + rb;
    console_putc('R');
    proc_exit(&g_procs, 0);
}

// Complete both requests, out of order, waking whoever is parked. Runs only because the
// waiter parked and yielded the CPU.
fn completer() -> void {
    console_putc('C');
    async_complete(&g_broker, &g_procs, g_id_b, 20);   // B first; no one parked on B yet
    async_complete(&g_broker, &g_procs, g_id_a, 22);   // wakes the waiter parked on A
    proc_exit(&g_procs, 0);
}

fn alloc_stack(h: *mut Heap) -> usize {
    let base: PAddr = heap_alloc(h, STACK_SIZE, 16);
    return pa_value(base) + STACK_SIZE;
}

export fn async_demo(region_base: usize, region_len: usize) -> u32 {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    proc_table_init(&g_procs);
    install_idle(&g_procs);
    async_init(&g_broker);
    g_result = 0;
    proc_spawn(&g_procs, alloc_stack(&heap), waiter);     // pid 1: parks first
    proc_spawn(&g_procs, alloc_stack(&heap), completer);  // pid 2: completes -> wakes pid 1

    var done: u32 = 0;
    while done < 2 {
        switch proc_wait(&g_procs, 0) {
            ok(info) => { done = done + 1; }
            err(e) => { done = 2; }
        }
    }
    return g_result as u32;   // 42 iff both completions reached the parked/awaited waiter
}
