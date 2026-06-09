// Preemptive scheduling: three worker threads that never yield. The timer
// interrupt drives `sched_yield`, so the scheduler rotates through them on its own.
// Each worker prints its letter once (proving the timer preempted *into* it, since
// nothing yields cooperatively) and then spins; `main` likewise just spins. Output
// "ABC" therefore proves all three were preempted to, and "PREEMPT-OK" that the
// bootstrap regained control and the run finished.

import "kernel/core/sched.mc";
import "kernel/core/console.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const STACK_SIZE: usize = 8192;
const TICK_TARGET: u32 = 24;
const NEVER: u32 = 1_000_000_000; // a spin bound the short test never reaches

global g_sched: Scheduler;
global g_ticks: atomic<u32> = atomic.init(0);

// Arm the timer + install the trap path (runtime), and reschedule the next tick.
extern fn mc_timer_start() -> void;
extern fn mc_timer_rearm() -> void;

// Called from the timer trap (interrupts disabled): count the tick, rearm, and
// round-robin to the next thread — preemption.
export fn timer_preempt() -> void {
    g_ticks.fetch_add(1, .acq_rel);
    mc_timer_rearm();
    sched_yield(&g_sched);
}

export fn tick_count() -> u32 {
    return g_ticks.load(.acquire);
}

// A worker spins reading the tick counter (a real load — a side effect, so the
// spin is not an empty/UB infinite loop the optimizer can delete) until a bound it
// never reaches; the timer preempts it long before that.
fn worker_a() -> void {
    console_putc('A');
    while tick_count() < NEVER {
    }
}
fn worker_b() -> void {
    console_putc('B');
    while tick_count() < NEVER {
    }
}
fn worker_c() -> void {
    console_putc('C');
    while tick_count() < NEVER {
    }
}

fn alloc_stack(h: *mut Heap) -> usize {
    let base: PAddr = heap_alloc(h, STACK_SIZE, 16);
    return pa_value(base) + STACK_SIZE;
}

export fn preempt_demo(region_base: usize, region_len: usize) -> u32 {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    sched_init(&g_sched);
    sched_spawn(&g_sched, alloc_stack(&heap), worker_a);
    sched_spawn(&g_sched, alloc_stack(&heap), worker_b);
    sched_spawn(&g_sched, alloc_stack(&heap), worker_c);

    mc_timer_start();
    while tick_count() < TICK_TARGET {
    }
    return tick_count();
}
