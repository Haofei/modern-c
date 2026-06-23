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
// Phase C will drive `async_complete` from a device interrupt (virtio-blk/net) instead of a
// cooperative completer; the IRQ wake path must stay IRQ-safe (no heap, no blocking, no
// dynamic dispatch) — it only marks the slot ready and wakes.

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

// Park the current task until request `id` completes; return its result and free the slot.
// While not ready, `wq_wait` blocks the task (proc_park) and yields to the next runnable task
// or `wfi` — so this does NOT busy-spin. Re-checks readiness on each wake (spurious-wake safe).
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

// Mark request `id` complete with `result` and wake every task parked on it. Returns false if
// `id` is not an active in-flight request. Phase C calls this from an interrupt handler.
export fn async_complete(b: *mut AsyncBroker, t: *mut ProcTable, id: u64, result: i32) -> bool {
    let s: usize = find_slot(b, id);
    if s >= MAX_INFLIGHT {
        return false;
    }
    b.slots[s].ready = true;
    b.slots[s].result = result;
    wq_wake_all(&b.slots[s].waiter, t);
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
