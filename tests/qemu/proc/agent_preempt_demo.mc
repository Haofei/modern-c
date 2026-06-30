// Timer-driven PREEMPTION of agent PROCESSES (ProcTable), end-to-end on real hardware.
//
// Unlike preempt_demo.mc (which preempts kernel THREADS via the Scheduler), this preempts
// processes spawned in a ProcTable. The bootstrap (slot 0) spawns three never-yielding worker
// processes, gives each a small quantum (proc_schedctl), and starts the CLINT timer. The timer
// ISR (timer_preempt in the runtime) calls the irq-safe DECISION layer proc_preempt_tick: it
// accounts one tick to the running process and, on the quantum-expiry edge, raises need_resched.
//
// The actual context switch is a may-sleep op and is FORBIDDEN from an `#[irq_context]` path
// ("scheduling while atomic"), so it is NOT done in the ISR. Instead each process consumes the
// flag at a safe PREEMPTION POINT (preempt_safepoint, in normal context): it polls
// proc_preempt_pending() and, when set, clears it and switches. This is the proven set-flag-in-
// ISR / switch-at-safe-point model the proc_sched decision layer is built for. The workers never
// yield COOPERATIVELY (they only react to the timer-raised flag), so each printing its letter
// proves the timer preempted *into* it.
//
// We switch with round-robin proc_yield rather than proc_preempt_point's priority policy
// (proc_yield_priority): the priority policy always runs the single highest-priority runnable
// process and would bounce between the two highest, never visiting all three workers. Round-robin
// rotates 0 -> A -> B -> C -> 0, so "ABC" proves every worker was preempted-to and the bootstrap
// then regains control (its quantum already spent, it spins to the target and returns) -> the
// runtime prints "AGENT-PREEMPT-OK".

import "kernel/core/process.mc";
import "kernel/core/proc_sched.mc";
import "kernel/core/console.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const STACK_SIZE: usize = 8192;
const TICK_TARGET: u32 = 32;        // bootstrap spins until this many ticks, then returns
const NEVER: u32 = 1_000_000_000;   // a spin bound the short test never reaches
const SMALL_QUANTUM: u32 = 3;       // ticks before the timer expires a process and forces a switch

global g_t: ProcTable;
global g_ticks: atomic<u32> = atomic.init(0);

// Arm the timer + install the trap path (runtime), and reschedule the next tick.
extern fn mc_timer_start() -> void;
extern fn mc_timer_rearm() -> void;

// Called from the timer trap (interrupts disabled): count the tick, rearm, and run the irq-safe
// preemption DECISION — account a tick to the running process and raise need_resched on quantum
// expiry. No context switch here (that would be scheduling-while-atomic); the switch happens at a
// safe point below.
export fn timer_preempt() -> void {
    g_ticks.fetch_add(1, .acq_rel);
    mc_timer_rearm();
    proc_preempt_tick(&g_t);
}

export fn tick_count() -> u32 {
    return g_ticks.load(.acquire);
}

// Safe PREEMPTION POINT (normal context, never the ISR): if the timer raised need_resched (the
// running process's quantum expired), clear it and round-robin to the next runnable process.
fn preempt_safepoint() -> void {
    if proc_preempt_pending() {
        proc_preempt_clear();
        proc_yield(&g_t);
    }
}

// A worker prints its letter once (proving the timer preempted into it, since it never yields
// cooperatively), then spins reading the tick counter (a real load — a side effect, so the spin
// is not an empty/UB loop the optimizer can delete), polling the safe point so the timer-raised
// reschedule actually switches it out.
fn worker_a() -> void {
    console_putc('A');
    while tick_count() < NEVER {
        preempt_safepoint();
    }
}
fn worker_b() -> void {
    console_putc('B');
    while tick_count() < NEVER {
        preempt_safepoint();
    }
}
fn worker_c() -> void {
    console_putc('C');
    while tick_count() < NEVER {
        preempt_safepoint();
    }
}

fn alloc_stack(h: *mut Heap) -> usize {
    let base: PAddr = heap_alloc(h, STACK_SIZE, 16);
    return pa_value(base) + STACK_SIZE;
}

export fn agent_preempt_demo(region_base: usize, region_len: usize) -> u32 {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    proc_table_init(&g_t);
    proc_spawn(&g_t, alloc_stack(&heap), worker_a); // pid 1
    proc_spawn(&g_t, alloc_stack(&heap), worker_b); // pid 2
    proc_spawn(&g_t, alloc_stack(&heap), worker_c); // pid 3

    // Give the bootstrap and every worker a small quantum so the timer expires the running
    // process after a few ticks and forces a switch (equal priority -> pure round-robin order).
    proc_schedctl(&g_t, 0, 0, SMALL_QUANTUM, 0);
    proc_schedctl(&g_t, 1, 0, SMALL_QUANTUM, 0);
    proc_schedctl(&g_t, 2, 0, SMALL_QUANTUM, 0);
    proc_schedctl(&g_t, 3, 0, SMALL_QUANTUM, 0);

    mc_timer_start();
    // The bootstrap's own spin: once its quantum expires the timer rotates it through the workers
    // (0 -> A -> B -> C -> 0); back in control with its quantum spent it just spins to the target.
    while tick_count() < TICK_TARGET {
        preempt_safepoint();
    }
    return tick_count();
}
