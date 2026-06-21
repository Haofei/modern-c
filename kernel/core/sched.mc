// kernel/core/sched — a cooperative round-robin scheduler over kernel threads.
//
// Holds a fixed set of saved register contexts; slot 0 is the bootstrap (the
// context that called `sched_init`), filled in on the first switch out of it.
// `sched_yield` round-robins to the next context. Thread stacks are supplied by
// the caller (allocated from the kernel heap / frame allocator), and entries are
// `fn() -> void` function pointers — no raw addresses here. Cooperative for now
// (threads yield); timer-tick preemption is the next step.

import "kernel/arch/active/context.mc"; // arch-selection seam (R0b); --arch picks context, default riscv64

const MAX_THREADS: usize = 8;

struct Scheduler {
    contexts: [MAX_THREADS]Context,
    count: usize,   // registered contexts (slot 0 = bootstrap)
    current: usize, // index of the running context
}

// Reserve slot 0 for the running (bootstrap) context. Zero-initialized storage is
// fine: slot 0's registers are written by the first `sched_yield` out of it.
export fn sched_init(s: *mut Scheduler) -> void {
    s.count = 1;
    s.current = 0;
}

// Register a thread that runs `entry` on the stack ending at `stack_top`. Traps if
// the table is full (a fixed-capacity scheduler; callers gate on `MAX_THREADS`).
export fn sched_spawn(s: *mut Scheduler, stack_top: usize, entry: fn() -> void) -> void {
    if s.count >= MAX_THREADS {
        unreachable; // scheduler table full
    }
    let slot: usize = s.count;
    mc_thread_init(&s.contexts[slot], stack_top, entry);
    s.count = s.count + 1;
}

// Cooperative round-robin: save the current context and switch to the next.
//
// C2: yielding the CPU is the canonical sleepable op — doing it from an
// `#[irq_context]` function is "scheduling while atomic", a compile error.
#[may_sleep]
export fn sched_yield(s: *mut Scheduler) -> void {
    if s.count == 0 {
        unreachable; // nothing to schedule
    }
    let from: usize = s.current;
    let to: usize = (s.current + 1) % s.count;
    s.current = to;
    mc_switch_context(&s.contexts[from], &s.contexts[to]);
}

export fn sched_count(s: *mut Scheduler) -> usize {
    return s.count;
}

export fn sched_current(s: *mut Scheduler) -> usize {
    return s.current;
}
