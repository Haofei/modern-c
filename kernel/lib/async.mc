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
// SCOPE: BOTH the cooperative path AND the IRQ-driven path now exist (Phase C landed; see
// async_await_irq below and the async-irq/blk/net gates). `async_complete` may be called either
// from another TASK (cooperative) or from a device interrupt (virtio-blk/net). The lost-wake race
// this module guards against: a completion arriving between a waiter's `ready` check and its
// enqueue would be LOST — the waiter would park on a slot that is already ready and sleep forever.
// Two things make the IRQ path safe, and both are now in place: (1) the IRQ wake path stays
// IRQ-safe — `async_complete` only marks state and wakes one waiter (no heap, no blocking, no
// dynamic dispatch); and (2) `async_await_irq` runs an IRQ-off critical section that enqueues the
// waiter THEN re-checks `ready`, closing the check-then-park window. The plain cooperative
// `async_await` remains valid ONLY when `async_complete` cannot fire from an ISR for that slot
// (control yields only AT `wq_wait`); use `async_await_irq` for any slot an interrupt may complete.

import "kernel/lib/waitqueue.mc";
import "kernel/core/process.mc";

// Mirrors user/abi.mc MAX_INFLIGHT: the max concurrent in-flight requests (and the hard
// bound on how many tasks can be parked on completions at once).
//
// CAPACITY CONTRACT. This is the GLOBAL in-flight cap — the total number of broker slots shared
// across EVERY async request kind at once. A per-backend leaf may impose a tighter cap of its own
// (e.g. kernel/drivers/virtio/virtio_blk_async.mc's BLK_ASYNC_MAX = VRING_QSIZE/3 = 2 reads,
// descriptor-bound); a request then needs BOTH a free global broker slot AND a free per-backend
// slot, so the effective concurrency for that kind is min(MAX_INFLIGHT, that backend's cap). The
// agent-side pump (user/agent_async.mc PUMP_STASH/PUMP_BATCH) is sized == MAX_INFLIGHT so it can
// always stash every completion the broker may deliver. Keep these in sync if MAX_INFLIGHT changes.
const MAX_INFLIGHT: usize = 8;

// Returned by async_submit when the MAX_INFLIGHT quota is exhausted.
pub const ASYNC_NO_ID: u64 = 0xFFFF_FFFF_FFFF_FFFF;

struct Inflight {
    active: bool,
    ready: bool,
    id: u64,
    result: i32,
    waiter: WaitQueue,   // tasks parked awaiting THIS request
}

pub struct AsyncBroker {
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

// The index of the active slot holding request `id`, or MAX_INFLIGHT if none. `#[irq_context]`:
// a bounded scan of comparisons, no calls — safe on the ISR completion path (async_complete).
#[irq_context]
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

// Phase C: IRQ-SAFE await for completions delivered from INTERRUPT context. The injected
// arch primitives keep this module arch-neutral; the riscv platform passes
// `disable_interrupts_global` / `enable_interrupts_global` / `wait_for_interrupt`.
//
// PRECONDITION: must be entered with interrupts ENABLED. It disables them for each critical
// section and leaves them ENABLED on return. (It uses plain disable/enable, not save/restore,
// so calling it with interrupts already off would wrongly re-enable them.)
//
// Correctness against an ISR completion (no lost wake, no lost idle). Interrupts stay OFF
// across "decide to wait", "enqueue+park", AND the idle `wfi`. RISC-V `wfi` resumes when a
// locally-enabled interrupt (e.g. the timer, `mie.MTIE`) is PENDING, regardless of the GLOBAL
// enable (`mstatus.MIE`) — and `irq_off` clears only the global bit. So:
//   - the completion cannot be lost between the ready-check and the park (interrupts are off);
//   - `wfi` is reached with interrupts off, so a completion that fires here stays PENDING and
//     wakes `wfi` rather than being taken-and-serviced before we idle (the lost-idle race);
//   - we then briefly enable interrupts to TAKE the pending ISR (which runs `async_complete` ->
//     `proc_unblock(current)`), disable again, and re-check `proc_current_blocked`. Once the ISR
//     has cleared our block we stop idling and the outer loop re-checks `ready`.
// Single task / single waiter per id (it `wfi`-idles rather than yielding to other runnable
// tasks; integrating this with preemptive multi-task scheduling is broader scheduler work).
export fn async_await_irq(b: *mut AsyncBroker, t: *mut ProcTable, id: u64,
                          irq_off: fn() -> void, irq_on: fn() -> void, wfi: fn() -> void) -> i32 {
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
            if parked {
                // Idle until the ISR clears our block. Interrupts stay OFF except for the brief
                // enable that lets the pending completion interrupt actually be taken.
                while proc_current_blocked(t) {
                    (wfi)();      // resumes on the pending completion (interrupts still off)
                    (irq_on)();   // take it now: ISR -> async_complete -> proc_unblock(current)
                    (irq_off)();
                }
            }
            (irq_on)();
        }
    }
    return result;
}

// Mark request `id` complete with `result` and wake its (single) awaiter. Returns false if `id`
// is not an active in-flight request. `wq_wake_one` matches the single-consumer contract above
// (the awaiter consumes+frees the slot, so a broadcast would leave later wakers with no result).
//
// Phase C calls this from an interrupt handler. It is IRQ-safe BY CONSTRUCTION: it only marks
// slot state and wakes one waiter via `wq_wake_one` -> `proc_unblock` (an atomic bit-clear) — no
// heap, no blocking, no dynamic dispatch; the only loops (find_slot, wq_wake_one) are bounded by
// MAX_INFLIGHT / WQ_MAX. The lost-wake window is closed on the await side by async_await_irq.
//
// NOW ENFORCED with `#[irq_context]`. The entire wake chain is annotated and MIR-verified
// irq-safe: async_complete -> find_slot / wq_wake_one -> ring_is_empty/ring_pop, endpoint_slot,
// proc_unblock -> mask32_clear. (The MIR irq-context verifier flags only CALLS — to a non-irq
// callee, an indirect call, or a known-blocking one; `endpoint_slot` returning a `Result` is fine
// because Result construction is not a call. The earlier "verifier rejects Result" note was a
// misdiagnosis: the real requirement was simply annotating the whole chain.)
#[irq_context]
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

// Cancel an in-flight request `id`: free its slot and release any task parked on it. After
// cancel the id is UNKNOWN (`find_slot` no longer matches), so the slot is immediately reusable
// by `async_submit`, and a late `async_complete(id)` (e.g. a device interrupt for an op whose
// future was dropped) finds nothing and is a harmless no-op. This is the broker primitive behind
// dropping a still-pending future: without it a dropped future LEAKS its `MAX_INFLIGHT` slot
// (and an enqueued waiter), which on an agent OS — tiny `MAX_INFLIGHT` — eventually wedges
// submission. Returns false if `id` is not an active request (idempotent: a second cancel, or a
// cancel of an already-completed/consumed id, is a no-op).
//
// CONTRACT: the single owner of a future cancels it; it is NOT simultaneously parked in
// `async_await(id)` on the same id (a task cannot both await and cancel). Defensively we still
// `wq_wake_one` so that IF a waiter were parked, it resumes, re-runs `find_slot`, sees the slot
// gone, and returns 0 rather than parking forever. IRQ-safe by the same construction as
// `async_complete` (only marks slot state + an atomic bit-clear wake; bounded loops, no heap).
export fn async_cancel(b: *mut AsyncBroker, t: *mut ProcTable, id: u64) -> bool {
    let s: usize = find_slot(b, id);
    if s >= MAX_INFLIGHT {
        return false;
    }
    b.slots[s].active = false;   // free immediately; a later async_complete(id) matches nothing
    b.slots[s].ready = false;
    let _woke: bool = wq_wake_one(&b.slots[s].waiter, t);
    return true;
}

// One harvested completion: the request id and its result. Filled by `async_poll_many`.
struct AsyncEvent {
    id: u64,
    result: i32,
}

// A fixed-size drain buffer (bounded by MAX_INFLIGHT — at most that many can be in flight, so at
// most that many completions exist at once). `count` is how many of `ev` are valid after a drain.
const ASYNC_MAX_EVENTS: usize = MAX_INFLIGHT;
pub struct AsyncEvents {
    count: usize,
    ev: [ASYNC_MAX_EVENTS]AsyncEvent,
}

// An empty drain buffer. Callers must declare their buffer with a whole-value init
// (definite-init S0.1: the out-pointer fill inside `async_poll_many` does not count),
// and a [8]AsyncEvent literal is not something to ask of every call site.
pub fn async_events_empty() -> AsyncEvents {
    let z: AsyncEvent = .{ .id = 0, .result = 0 };
    return .{ .count = 0, .ev = .{ z, z, z, z, z, z, z, z } };
}

// VECTORED drain: harvest up to `max` COMPLETED in-flight requests into `out.ev[0..]`, freeing each
// drained slot, and return the count (also stored in `out.count`). One scheduler wakeup can collect
// many completions in a single pass over the inflight table — the kernel-side analogue of the
// broker's `SYS_POLL(events, max)` (the Phase-A note deferred this here: the drain iterates the
// fixed, typed inflight table rather than doing `*dyn` fat-pointer arithmetic in pure std).
//
// This is the DRAIN-driven completion model: the caller owns dispatch of the harvested events. It
// CONSUMES (frees) each ready slot, so do NOT also have a task parked in `async_await`/`_irq` on a
// drained id (that is the park/wake model — pick one per id). A still-pending (not-ready) slot is
// left untouched, so a later drain resumes where this one stopped (the `max` cap is re-enterable).
export fn async_poll_many(b: *mut AsyncBroker, out: *mut AsyncEvents, max: usize) -> usize {
    var n: usize = 0;
    var i: usize = 0;
    while i < MAX_INFLIGHT {
        if n >= max {
            out.count = n;
            return n;
        }
        if b.slots[i].active && b.slots[i].ready {
            out.ev[n].id = b.slots[i].id;
            out.ev[n].result = b.slots[i].result;
            b.slots[i].active = false;   // consume + free the slot
            n = n + 1;
        }
        i = i + 1;
    }
    out.count = n;
    return n;
}

// Read and CONSUME a completed request's result, freeing its slot. Precondition: `id` is ready
// (check `async_slot_ready` first). Returns 0 for an unknown/already-consumed id. Single-consumer —
// the Future-leaf `ReqFut` (kernel/lib/async_future.mc) calls this once, from its poll, when the
// slot becomes ready (the broker analogue of `async_await`'s result read, but non-blocking).
export fn async_take(b: *mut AsyncBroker, id: u64) -> i32 {
    let s: usize = find_slot(b, id);
    if s >= MAX_INFLIGHT {
        return 0;
    }
    let r: i32 = b.slots[s].result;
    b.slots[s].active = false;   // consume + free the slot
    return r;
}

// Free an in-flight slot WITHOUT waking a waiter — the Future-based executor (`drive_irq`) parks in
// `wfi`, not on the slot's wait queue, so a dropped `ReqFut` has no parked waiter to release. This
// is the leaf-cancel primitive behind a dropped async future (`ReqFut_cancel`); it reclaims the
// slot so a future abandoned mid-flight does not leak its `MAX_INFLIGHT` reservation. Returns false
// if `id` is not active (idempotent).
export fn async_cancel_slot(b: *mut AsyncBroker, id: u64) -> bool {
    let s: usize = find_slot(b, id);
    if s >= MAX_INFLIGHT {
        return false;
    }
    b.slots[s].active = false;
    b.slots[s].ready = false;
    return true;
}

// How many inflight slots are currently reserved (active). A test/observability hook: after a
// race cancels the loser and the winner is consumed, this must return to 0 — proof that no slot
// leaked (the MAX_INFLIGHT-returns-to-zero acceptance for cancellation).
export fn async_active_count(b: *mut AsyncBroker) -> usize {
    var n: usize = 0;
    var i: usize = 0;
    while i < MAX_INFLIGHT {
        if b.slots[i].active {
            n = n + 1;
        }
        i = i + 1;
    }
    return n;
}

// The id of some active, not-yet-ready in-flight request, or ASYNC_NO_ID if none. Lets a device/
// timer ISR complete "the request currently in flight" without threading the id through a global.
// IRQ-safe: a bounded scan of field reads, no calls — runs on the ISR completion path alongside
// `async_complete`, so it is #[irq_context] and the whole handler is compiler-verified.
#[irq_context]
export fn async_first_active_unready(b: *mut AsyncBroker) -> u64 {
    var i: usize = 0;
    while i < MAX_INFLIGHT {
        if b.slots[i].active && !b.slots[i].ready {
            return b.slots[i].id;
        }
        i = i + 1;
    }
    return ASYNC_NO_ID;
}

// The HIGHEST id among active, not-yet-ready in-flight requests, or ASYNC_NO_ID if none. Lets a
// device/timer ISR complete in-flight requests in a deterministic OUT-OF-SUBMISSION order (ids are
// monotonic, so highest-id == most-recently-submitted) — used by the E6 multi-future executor gate
// to prove its futures resolve interleaved rather than serially. IRQ-safe: a bounded scan of field
// reads, no calls, so #[irq_context] like `async_first_active_unready`.
#[irq_context]
export fn async_highest_active_unready(b: *mut AsyncBroker) -> u64 {
    var best: u64 = ASYNC_NO_ID;
    var found: bool = false;
    var i: usize = 0;
    while i < MAX_INFLIGHT {
        if b.slots[i].active && !b.slots[i].ready {
            if !found {
                best = b.slots[i].id;
                found = true;
            } else {
                if b.slots[i].id > best {
                    best = b.slots[i].id;
                }
            }
        }
        i = i + 1;
    }
    return best;
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
