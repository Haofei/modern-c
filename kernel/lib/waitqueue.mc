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

// Block the current process on this queue: record its endpoint, park it (non-runnable), and
// yield. It resumes after a waker validates its endpoint and wakes it.
export fn wq_wait(q: *mut WaitQueue, t: *mut ProcTable) -> void {
    let me: Endpoint = proc_self_endpoint(t);
    // Only block if we were actually recorded as a waiter; a full queue means no waker can
    // find us, so returning (the caller re-checks) is safer than parking unreachably.
    if ring_push(Endpoint, WQ_MAX, &q.waiters, me) {
        proc_park(t);
        proc_yield_or_idle(t);
    }
}

// Wake the oldest *live* waiter (FIFO), skipping any whose endpoint is now stale (the waiter
// exited and its slot may have been reused). Returns false if no live waiter remained.
export fn wq_wake_one(q: *mut WaitQueue, t: *mut ProcTable) -> bool {
    var scanning: bool = true;
    while scanning {
        if ring_is_empty(Endpoint, WQ_MAX, &q.waiters) {
            scanning = false;
        } else {
            let ep: Endpoint = ring_pop(Endpoint, WQ_MAX, &q.waiters);
            switch endpoint_slot(t, ep) {
                ok(slot) => {
                    proc_unblock(t, slot, BLOCK_RECV);
                    return true;
                }
                err(e) => {} // stale endpoint: drop it and try the next waiter
            }
        }
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
