// kernel/lib/waitqueue — a FIFO wait queue (condition-variable-style) over the process
// table. Centralizes the "block the current process, wake a waiter" policy that ipc_receive
// and friends would otherwise hand-roll: a process waits (enqueues itself, parks, yields),
// and a waker wakes the oldest waiter (or all of them) when the awaited condition holds.
//
// Waiters are stored as generation-checked `Endpoint`s (not raw pids), so a waiter that
// exited and had its slot reused does NOT wake the new occupant — a stale entry is validated
// and skipped on wake. The block/wake transitions go through the core mechanisms.

import "kernel/core/process.mc";
import "std/ring.mc";

const WQ_MAX: usize = 8;

struct WaitQueue {
    waiters: Ring<Endpoint, WQ_MAX>, // endpoints blocked on this queue, oldest first
}

export fn wq_init(q: *mut WaitQueue) -> void {
    ring_init(Endpoint, WQ_MAX, &q.waiters);
}

export fn wq_len(q: *mut WaitQueue) -> usize {
    return ring_len(Endpoint, WQ_MAX, &q.waiters);
}

// Enqueue the current process on this queue and mark it parked (non-runnable), WITHOUT
// yielding. Returns true if it was enqueued (and thus reachable by a waker). Splitting the
// enqueue+park from the yield lets a caller bracket the enqueue with an interrupts-off critical
// section so a wake delivered from interrupt context between "decide to wait" and "park" cannot
// be lost: once enqueued+parked here (interrupts off), a later `wq_wake_one` will find and
// unblock this process. The caller then re-enables interrupts and yields. A full queue returns
// false (no waker could find us) — do NOT yield in that case; re-check the condition instead.
export fn wq_prepare_wait(q: *mut WaitQueue, t: *mut ProcTable) -> bool {
    let me: Endpoint = proc_self_endpoint(t);
    if ring_push(Endpoint, WQ_MAX, &q.waiters, me) {
        proc_park(t);
        return true;
    }
    return false;
}

// Block the current process on this queue: record its endpoint, park it (non-runnable), and
// yield. It resumes after a waker validates its endpoint and wakes it. (The cooperative form;
// for completions delivered from interrupt context use wq_prepare_wait under an irq-off section.)
export fn wq_wait(q: *mut WaitQueue, t: *mut ProcTable) -> void {
    if wq_prepare_wait(q, t) {
        proc_yield_or_idle(t);
    }
}

// Wake the oldest *live* waiter (FIFO), skipping any whose endpoint is now stale (the waiter
// exited and its slot may have been reused). Returns false if no live waiter remained. Called
// from an ISR via async_complete, so it stays non-blocking (ring + generation-check +
// proc_unblock) and is `#[irq_context]`-verified: its callees (ring_is_empty/ring_pop,
// endpoint_slot, proc_unblock) are all irq-safe (endpoint_slot's `Result` is fine — Result
// construction is not a call, which is all the irq-context verifier flags).
#[irq_context]
export fn wq_wake_one(q: *mut WaitQueue, t: *mut ProcTable) -> bool {
    // Bounded scan: the ring holds at most WQ_MAX waiters, so at most WQ_MAX pops drain it.
    var i: usize = 0;
    while i < WQ_MAX {
        if ring_is_empty(Endpoint, WQ_MAX, &q.waiters) {
            return false;
        }
        let ep: Endpoint = ring_pop(Endpoint, WQ_MAX, &q.waiters);
        // Sentinel (not Result) lookup: Result construction is not irq-safe (see endpoint_slot_or).
        let slot: usize = endpoint_slot_or(t, ep, t.count);
        if slot < t.count {
            proc_unblock(t, slot, BLOCK_RECV);
            return true;
        }
        // stale endpoint (slot == t.count): drop it and try the next waiter.
        i = i + 1;
    }
    return false;
}

// Wake every live waiter (e.g., a broadcast when a shared condition becomes true).
export fn wq_wake_all(q: *mut WaitQueue, t: *mut ProcTable) -> void {
    var more: bool = true;
    while more {
        more = wq_wake_one(q, t);
    }
}
