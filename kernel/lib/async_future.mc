// kernel/lib/async_future.mc — the bridge from the compiler's `async fn`/`await` lowering to the
// real kernel completion broker (kernel/lib/async.mc). The async transform lowers `await e` into
// calls on a child future's uniform leaf ABI (`<F>__poll` / `<F>_take_result` / `<F>_cancel`);
// this module supplies a broker-backed leaf `ReqFut` that satisfies that ABI over an in-flight
// request id, plus `drive_irq`, an IRQ-backed executor that drives such a future to completion
// while sleeping in `wfi`. Together they let an `async fn` `await` real device/timer completions:
//
//     async fn f(b: *mut AsyncBroker) -> i32 {
//         let x: i32 = await req_begin(b);   // suspend until an IRQ async_completes this request
//         let y: i32 = await req_begin(b);
//         return x + y;
//     }
//
// The generated `poll` only polls `ReqFut`s (non-blocking); the single blocking point is the
// `drive_irq` driver. So `await` is a suspend, never a park (the stackless invariant, spec §33.2).

import "kernel/lib/async.mc";
import "std/task.mc";

// A broker-backed FUTURE leaf: a submitted request id presented as a `Future`. `req_begin(b)` (the
// awaited call) reserves a slot; `poll` reports readiness via `async_slot_ready` and, on the edge
// to ready, reads+frees the result (`async_take`); `ReqFut_take_result` yields it once;
// `ReqFut_cancel` frees a still-pending slot on drop (`async_cancel_slot`) — so a dropped async
// future reclaims its `MAX_INFLIGHT` reservation. `ready` latches so `poll` stays idempotent and
// the result survives the slot's release.
struct ReqFut {
    b: *mut AsyncBroker,
    id: u64,
    ready: bool,
    result: i32,
}

// The awaited constructor: reserve a broker slot and return a future over it. The caller arms the
// actual operation (a device or the timer) that will `async_complete` this id. If the MAX_INFLIGHT
// quota is exhausted the id is ASYNC_NO_ID and the future completes immediately with 0 (the caller
// must back-pressure on submission to avoid that).
export fn req_begin(b: *mut AsyncBroker) -> ReqFut {
    var f: ReqFut = uninit;
    f.b = b;
    f.id = async_submit(b);
    f.ready = false;
    f.result = 0;
    return f;
}

// A future over an ALREADY-RESERVED broker id. Used when the operation that will `async_complete`
// the id is armed by a separate submit path (e.g. a device driver that calls `async_submit` itself
// to tie the slot to a hardware descriptor) — the caller passes the resulting id here rather than
// having the future reserve a fresh slot. Same poll/take/cancel ABI as `req_begin`'s future.
export fn req_over(b: *mut AsyncBroker, id: u64) -> ReqFut {
    var f: ReqFut = uninit;
    f.b = b;
    f.id = id;
    f.ready = false;
    f.result = 0;
    return f;
}

impl Future for ReqFut {
    fn poll(self: *mut ReqFut) -> bool {
        if self.ready {
            return true;
        }
        if async_slot_ready(self.b, self.id) {
            self.result = async_take(self.b, self.id);   // read + free on the ready edge
            self.ready = true;
            return true;
        }
        return false;
    }
    // Drop a still-pending request: free its broker slot (E1 — `cancel` is now in the Future vtable,
    // so a type-erased `*mut dyn Future` over a ReqFut can be cancelled by the generic combinators).
    // No-op once `ready` (the slot was already consumed by completion). Idempotent.
    fn cancel(self: *mut ReqFut) -> void {
        if !self.ready {
            let _freed: bool = async_cancel_slot(self.b, self.id);
        }
    }
}

export fn ReqFut_take_result(self: *mut ReqFut) -> i32 {
    return self.result;
}

// Free-function alias kept for concrete callers (and the generated async cancel ABI); mirrors the
// trait method. The type-erased path goes through the vtable `cancel` above.
export fn ReqFut_cancel(self: *mut ReqFut) -> void {
    if !self.ready {
        let _freed: bool = async_cancel_slot(self.b, self.id);
    }
}

// ---- select / timeout cleanup built on cancellation ----------------------------------------
// `ReqRace2` races two in-flight broker requests: it completes when EITHER finishes and CANCELS
// the loser (`ReqFut_cancel` -> `async_cancel_slot`), so the loser's MAX_INFLIGHT slot is
// reclaimed rather than leaked. `winner` records which finished first (0 = a, 1 = b; -1 while
// undecided). This is the cancellation-dependent primitive an agent needs to race two tool calls
// (or to time one out: race the operation against a deadline request — whichever loses is
// cancelled). E1 RESOLVED the vtable gap: `cancel` is now a `Future` trait method, so the generic
// `std/task.mc` `Race2` over `*mut dyn Future` also cancels its loser (see async_select_demo, which
// exercises both). `ReqRace2` is RETAINED as the TYPED-RESULT convenience: it reads the winner's
// `i32` result from the concrete `ReqFut` leaf (`req_race2_result`), which a type-erased `Race2`
// cannot — `poll` does not thread a typed value (see std/task.mc's "no generic poll result" note).
struct ReqRace2 {
    a: *mut ReqFut,
    b: *mut ReqFut,
    winner: i32,
}

export fn req_race2_init(r: *mut ReqRace2, a: *mut ReqFut, b: *mut ReqFut) -> void {
    r.a = a;
    r.b = b;
    r.winner = -1;
}

impl Future for ReqRace2 {
    fn poll(self: *mut ReqRace2) -> bool {
        if self.winner >= 0 {
            return true;
        }
        let ra: bool = ReqFut.poll(self.a);
        if ra {
            self.winner = 0;
            ReqFut_cancel(self.b);   // cancel the loser -> free its slot
            return true;
        }
        let rb: bool = ReqFut.poll(self.b);
        if rb {
            self.winner = 1;
            ReqFut_cancel(self.a);
            return true;
        }
        return false;
    }
    // Drop the race: cancel both leaves (E1 — `Future` now requires `cancel`). Idempotent: the
    // decided winner is `ready` (no-op) and the loser was cancelled in `poll`, so re-cancelling
    // here is harmless. A still-undecided race (dropped before any winner) frees both slots.
    fn cancel(self: *mut ReqRace2) -> void {
        ReqFut_cancel(self.a);
        ReqFut_cancel(self.b);
    }
}

export fn req_race2_winner(r: *mut ReqRace2) -> i32 {
    return r.winner;
}

// The winner's result (valid after the race completes). Reads from whichever leaf won.
export fn req_race2_result(r: *mut ReqRace2) -> i32 {
    if r.winner == 0 {
        return ReqFut_take_result(r.a);
    }
    return ReqFut_take_result(r.b);
}

// Drive a FUTURE to completion under IRQ-backed completion, sleeping in `wfi` until an interrupt
// makes progress. This GENERALIZES `async_await_irq` from a single request id to an arbitrary
// `Future` (which may hold any number of in-flight child requests): poll the future with interrupts
// OFF; while it is pending, idle in `wfi` (which resumes on a pending, locally-enabled completion
// interrupt even with the global enable cleared), then briefly enable interrupts to TAKE the ISR
// (which `async_complete`s a child), and re-poll. Interrupts stay OFF across the poll and the
// `wfi`, so a completion can be neither lost (taken before we park) nor idled-through — the same
// invariant `async_await_irq` relies on.
//
// PRECONDITION: entered with interrupts ENABLED; returns with interrupts ENABLED. It parks in
// `wfi` rather than yielding to other runnable tasks (integrating with preemptive scheduling is
// broader scheduler work), so it drives ONE top-level future on the current task.
export fn drive_irq(f: *mut dyn Future, irq_off: fn() -> void, irq_on: fn() -> void, wfi: fn() -> void) -> void {
    var done: bool = false;
    while !done {
        (irq_off)();
        if f.poll() {
            done = true;
            (irq_on)();
        } else {
            (wfi)();      // resumes on the pending completion interrupt (interrupts still off)
            (irq_on)();   // take it now: ISR -> async_complete(child); next iteration re-polls
        }
    }
}
