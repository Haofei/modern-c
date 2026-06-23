// kernel/lib/async.mc — async/await roadmap Phase B: a request-id-keyed park/wake
// completion broker. This is the kernel-side integration std/task.mc deliberately does NOT
// contain (std stays pure). It turns "poll until ready" into: submit -> park the task on the
// request's inflight slot -> a completion marks the slot ready and WAKES the task. The idle
// path is the kernel's existing `proc_yield_or_idle` -> idle_hook (`wfi`), so a waiting task
// sleeps instead of busy-spinning.
//
// Built on the proven primitives: one `WaitQueue` per inflight slot (endpoint-based,
// generation-safe park/wake via proc_park/proc_unblock — kernel/lib/waitqueue.mc). The table
// is fixed-size and STACKFUL by nature (each parked task holds its own kernel/user stack), so
// concurrency is quota-bound by MAX_INFLIGHT.
//
// SCOPE: Phase B is COOPERATIVE ONLY. `async_complete` is called from another TASK, not from
// an interrupt, so `async_await`'s check-then-park is race-free (control only yields AT
// `wq_wait`). Driving `async_complete` from a device interrupt (virtio-blk/net) is Phase C, and
// it requires TWO things this module does not yet have: (1) the IRQ wake path must stay IRQ-safe
// (no heap, no blocking, no dynamic dispatch — `async_complete` already only marks state and
// wakes one waiter), and (2) `async_await` must add an IRQ-off critical section that enqueues
// the waiter THEN re-checks `ready`, or a completion arriving between the check and the enqueue
// would be a LOST WAKE (the waiter parks on a slot that is already ready). See the contract on
// `async_await`. Do NOT wire `async_complete` to an ISR until that is in place.

import "kernel/lib/waitqueue.mc";
import "kernel/core/process.mc";

// Mirrors user/abi.mc MAX_INFLIGHT: the max concurrent in-flight requests (and the hard
// bound on how many tasks can be parked on completions at once).
const MAX_INFLIGHT: usize = 8;

// Returned by async_submit when the MAX_INFLIGHT quota is exhausted.
export const ASYNC_NO_ID: u64 = 0xFFFF_FFFF_FFFF_FFFF;

struct Inflight {
    active: bool,
    ready: bool,
    id: u64,
    result: i32,
    waiter: WaitQueue,   // tasks parked awaiting THIS request
}

struct AsyncBroker {
    slots: [MAX_INFLIGHT]Inflight,
    next_id: u64,
}

export fn async_init(b: *mut AsyncBroker) -> void {
    var i: usize = 0;
    while i < MAX_INFLIGHT {
        b.slots[i].active = false;
        b.slots[i].ready = false;
        b.slots[i].id = 0;
        b.slots[i].result = 0;
        wq_init(&b.slots[i].waiter);
        i = i + 1;
    }
    b.next_id = 0;
}

// The index of the active slot holding request `id`, or MAX_INFLIGHT if none.
fn find_slot(b: *mut AsyncBroker, id: u64) -> usize {
    var i: usize = 0;
    while i < MAX_INFLIGHT {
        if b.slots[i].active && b.slots[i].id == id {
            return i;
        }
        i = i + 1;
    }
    return MAX_INFLIGHT;
}

// Reserve an inflight slot and return its monotonic request id, or ASYNC_NO_ID if the
// MAX_INFLIGHT quota is full (the caller must back-pressure rather than over-commit).
export fn async_submit(b: *mut AsyncBroker) -> u64 {
    var i: usize = 0;
    while i < MAX_INFLIGHT {
        if !b.slots[i].active {
            let id: u64 = b.next_id;
            b.next_id = b.next_id + 1;
            b.slots[i].active = true;
            b.slots[i].ready = false;
            b.slots[i].id = id;
            b.slots[i].result = 0;
            wq_init(&b.slots[i].waiter);
            return id;
        }
        i = i + 1;
    }
    return ASYNC_NO_ID;
}

// Park the current (single) awaiter of request `id` until it completes; return its result and
// free the slot. While not ready, `wq_wait` blocks the task (proc_park) and yields to the next
// runnable task or `wfi` — so this does NOT busy-spin. Re-checks readiness on each wake.
//
// CONCURRENCY CONTRACT (Phase B = COOPERATIVE ONLY):
//   - Single-consumer: exactly ONE task awaits a given `id` (the one that submitted it). A slot
//     is consumed and freed by its awaiter, so a second awaiter of the same `id` is undefined —
//     do not share an id across tasks.
//   - This function is NOT yet safe against a completion delivered from INTERRUPT context. The
//     `ready` check and the `wq_wait` enqueue are two steps; a preemptive `async_complete`
//     (Phase C, from an ISR) landing between them would wake an empty queue and the waiter would
//     park forever (a lost wake). In cooperative Phase B this cannot happen — control only leaves
//     this task AT `wq_wait`, so nothing runs between the check and the enqueue. Phase C MUST add
//     an IRQ-off critical section that enqueues the waiter THEN re-checks `ready` (waking
//     itself if the completion already arrived) before `async_complete` is wired to an interrupt.
export fn async_await(b: *mut AsyncBroker, t: *mut ProcTable, id: u64) -> i32 {
    var done: bool = false;
    var result: i32 = 0;
    while !done {
        let s: usize = find_slot(b, id);
        if s >= MAX_INFLIGHT {
            // unknown id: already consumed, or never submitted.
            return 0;
        }
        if b.slots[s].ready {
            result = b.slots[s].result;
            b.slots[s].active = false;   // free the slot for reuse
            done = true;
        } else {
            wq_wait(&b.slots[s].waiter, t);
        }
    }
    return result;
}

// Phase C: IRQ-SAFE await for completions delivered from INTERRUPT context. `irq_off`/`irq_on`
// are the arch's interrupt disable/enable (injected so this module stays arch-neutral — the
// riscv platform passes disable/enable_interrupts_global). The readiness check and the
// enqueue-and-park run with interrupts OFF, closing the lost-wake window: an `async_complete`
// from an ISR cannot land between "saw not-ready" and "parked". By the time interrupts are
// re-enabled, this task is either already done, or enqueued+parked and reachable by the wake —
// so it then yields/`wfi` (interrupts now on) and the completing interrupt resumes it.
// Single-consumer, same as async_await.
export fn async_await_irq(b: *mut AsyncBroker, t: *mut ProcTable, id: u64, irq_off: fn() -> void, irq_on: fn() -> void) -> i32 {
    var done: bool = false;
    var result: i32 = 0;
    while !done {
        (irq_off)();
        let s: usize = find_slot(b, id);
        if s >= MAX_INFLIGHT {
            (irq_on)();
            return 0;
        }
        if b.slots[s].ready {
            result = b.slots[s].result;
            b.slots[s].active = false;
            (irq_on)();
            done = true;
        } else {
            // Enqueue + park with interrupts still OFF, so a completion cannot be lost.
            let parked: bool = wq_prepare_wait(&b.slots[s].waiter, t);
            (irq_on)();
            if parked {
                proc_yield_or_idle(t);   // sleep until the ISR completes us (interrupts now on)
            }
        }
    }
    return result;
}

// Mark request `id` complete with `result` and wake its (single) awaiter. Returns false if `id`
// is not an active in-flight request. `wq_wake_one` matches the single-consumer contract above
// (the awaiter consumes+frees the slot, so a broadcast would leave later wakers with no result).
//
// Phase C will call this from an interrupt handler; that path must stay IRQ-safe (no heap, no
// blocking, no dynamic dispatch — this function already only marks state and wakes) AND requires
// the IRQ-off wait-prepare in `async_await` noted above to avoid a lost wake.
export fn async_complete(b: *mut AsyncBroker, t: *mut ProcTable, id: u64, result: i32) -> bool {
    let s: usize = find_slot(b, id);
    if s >= MAX_INFLIGHT {
        return false;
    }
    b.slots[s].ready = true;
    b.slots[s].result = result;
    let _woke: bool = wq_wake_one(&b.slots[s].waiter, t);
    return true;
}

// Readiness predicate for std/task.mc's `SlotFuture` (the Phase-A injection seam): true once
// `id` has completed (or is unknown/already consumed). A `SlotFuture` whose `done` wraps this
// (over a global or captured broker) composes with join2/race2/timeout — the executor's idle
// hook can be `proc_yield_or_idle`, bridging the pure vocabulary to this kernel broker.
export fn async_slot_ready(b: *mut AsyncBroker, id: u64) -> bool {
    let s: usize = find_slot(b, id);
    if s >= MAX_INFLIGHT {
        return true;
    }
    return b.slots[s].ready;
}
