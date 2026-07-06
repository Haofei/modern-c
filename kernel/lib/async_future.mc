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
pub struct ReqFut {
    b: *mut AsyncBroker,
    id: u64,
    ready: bool,
    result: i32,
}

// The awaited constructor: reserve a broker slot and return a future over it. The caller arms the
// actual operation (a device or the timer) that will `async_complete` this id. If the MAX_INFLIGHT
// quota is exhausted the id is ASYNC_NO_ID and the future completes immediately with 0 (the caller
// must back-pressure on submission to avoid that).
pub fn req_begin(b: *mut AsyncBroker) -> ReqFut {
    return .{ .b = b, .id = async_submit(b), .ready = false, .result = 0 };
}

// A future over an ALREADY-RESERVED broker id. Used when the operation that will `async_complete`
// the id is armed by a separate submit path (e.g. a device driver that calls `async_submit` itself
// to tie the slot to a hardware descriptor) — the caller passes the resulting id here rather than
// having the future reserve a fresh slot. Same poll/take/cancel ABI as `req_begin`'s future.
pub fn req_over(b: *mut AsyncBroker, id: u64) -> ReqFut {
    return .{ .b = b, .id = id, .ready = false, .result = 0 };
}

impl Future for ReqFut {
    export fn poll(self: *mut ReqFut) -> bool {
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
pub struct ReqRace2 {
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

// E6 — a MULTI-FUTURE cooperative executor. `drive_many` generalizes `drive_irq` from ONE
// top-level future to a fixed array of N `*mut dyn Future`, driving ALL of them to completion
// while sleeping in `wfi` between ISR-delivered completions. This is the kernel-side concurrency
// the agent OS needs: several independent async operations (each holding its own broker request
// id) make progress INTERLEAVED as their child completions arrive from interrupt context, rather
// than serially via N sequential `drive_irq` calls — one `wfi`-idle services whichever future's
// completion the ISR delivered next.
//
// IDLE/PROGRESS DISCIPLINE (the lost-wakeup invariant, reused EXACTLY from `drive_irq` /
// `async_await_irq`). Each pass runs with interrupts OFF: poll every not-yet-`done[i]` future and
// count how many remain pending. The decision to idle is made WITH INTERRUPTS OFF, so a completion
// cannot land between "saw all pending" and the park:
//   - if `remaining == 0`, every future is complete — re-enable interrupts and return;
//   - if a future completed THIS pass (`remaining` dropped), loop immediately (interrupts off) and
//     re-poll — a sibling may now be unblocked, and we must not idle while progress is available;
//   - only if NO future completed this pass do we `wfi` (interrupts still off, so a pending
//     locally-enabled completion stays pending and wakes `wfi` rather than being serviced-then-
//     idled-through — the lost-idle race), then briefly `irq_on` to TAKE the pending ISR (which
//     `async_complete`s some child), and the next pass re-polls under interrupts-off again.
// This is the SAME race-free discipline `async_await_irq` documents; it is merely lifted over N
// futures with a "made progress?" gate so we never `wfi` while a just-arrived completion could
// unblock a sibling on the next poll.
//
// TEARDOWN. The loop only exits once ALL futures are `done`, so on the normal path nothing is
// pending. A bounded SAFETY BUDGET (`max_idle` consecutive idles with no progress) fails closed:
// if the budget is exhausted (a wedged/never-completing future — e.g. a missing device IRQ), we
// CANCEL every still-pending future via its E1 vtable `cancel` (reclaiming its broker slot, so no
// `MAX_INFLIGHT` slot leaks) and return. So a still-pending future at teardown is ALWAYS cancelled.
//
// PRECONDITION: entered with interrupts ENABLED; returns with interrupts ENABLED (plain
// disable/enable, like `async_await_irq`). Bounded + no heap: futures beyond `DRIVE_MANY_MAX` are
// IGNORED (the `done` bitmap is a fixed stack array; pass a slice of length <= DRIVE_MANY_MAX), no
// allocation (the `FutSet` array is caller-owned, fixed-size), no blocking call inside any `poll`
// (the stackless invariant). It parks the CURRENT task in `wfi` rather than yielding to other
// runnable tasks — see the deferred true-preemption note in docs/async-plan.md (E6).
//
// `max_idle` bounds consecutive no-progress idles before fail-closed teardown; pass a value large
// enough that every expected completion arrives within it (one `wfi` wakes per ISR). Returns the
// number of futures that completed normally (== n on the all-resolved path; < n iff the budget
// fired and the remainder were cancelled).
const DRIVE_MANY_MAX: usize = 16;

// A fixed, no-heap set of type-erased futures handed to `drive_many`. The array lives in the
// struct (a slice of `*dyn` fat pointers tripped a backend-parity gap in fat-pointer slice
// codegen, so we pass a pointer to this struct and index its array field — the same `b.slots[i]`
// pattern the broker uses). Fill `fs[0..n]` (n <= DRIVE_MANY_MAX) and set `n`. `&concrete` coerces
// to `*mut dyn Future` on element assignment.
pub struct FutSet {
    fs: [DRIVE_MANY_MAX]*mut dyn Future,
    n: usize,
}

// Initialize an empty set.
export fn futset_init(s: *mut FutSet) -> void {
    s.n = 0;
}

// Append a future to the set (no-op past DRIVE_MANY_MAX — fail closed). `f` is a `*mut dyn Future`
// (a coerced `&concrete`). Returns the slot index, or DRIVE_MANY_MAX if full.
export fn futset_push(s: *mut FutSet, f: *mut dyn Future) -> usize {
    if s.n >= DRIVE_MANY_MAX {
        return DRIVE_MANY_MAX;
    }
    let i: usize = s.n;
    s.fs[i] = f;
    s.n = i + 1;
    return i;
}

export fn drive_many(set: *mut FutSet, max_idle: u32,
                     irq_off: fn() -> void, irq_on: fn() -> void, wfi: fn() -> void) -> usize {
    // Clamp to the array bound UP FRONT so the FutSet.n invariant is enforced, not merely
    // tolerated: a manually-built set with n > DRIVE_MANY_MAX is silently capped (the slots past
    // the bound do not exist), and every loop below can iterate `0..n` without a per-iteration
    // bounds guard.
    var n: usize = set.n;
    if n > DRIVE_MANY_MAX {
        n = DRIVE_MANY_MAX;
    }
    // Whole-value init (definite-init S0.1: element-wise loop init does not count) — the
    // literal length is checked against DRIVE_MANY_MAX at compile time.
    var done: [DRIVE_MANY_MAX]bool = .{ false, false, false, false, false, false, false, false,
                                        false, false, false, false, false, false, false, false };
    var completed: usize = 0;
    var idle_streak: u32 = 0;
    var stop: bool = false;
    while !stop {
        (irq_off)();
        // Poll every still-pending future (interrupts OFF), counting completions THIS pass.
        var progressed: bool = false;
        var remaining: usize = 0;
        var k: usize = 0;
        while k < n {
            // n is clamped to DRIVE_MANY_MAX above, so set.fs[k]/done[k] are always in bounds.
            if !done[k] {
                let f: *mut dyn Future = set.fs[k];
                if f.poll() {
                    done[k] = true;
                    completed = completed + 1;
                    progressed = true;
                } else {
                    remaining = remaining + 1;
                }
            }
            k = k + 1;
        }
        if remaining == 0 {
            (irq_on)();
            stop = true;
        } else {
            if progressed {
                // Made progress: a sibling may now be unblocked. Re-poll without idling — never
                // `wfi` while a just-arrived completion could resolve another future next pass.
                (irq_on)();
                idle_streak = 0;
            } else {
                // No progress this pass. Idle for one completion (interrupts still OFF, so a
                // pending completion stays pending and wakes `wfi`), then take the ISR.
                idle_streak = idle_streak + 1;
                if idle_streak > max_idle {
                    // Fail closed: a future is wedged. Cancel every still-pending future (E1
                    // vtable `cancel` -> reclaims its broker slot) so no slot leaks, then return.
                    var j: usize = 0;
                    while j < n {
                        if !done[j] {
                            let fc: *mut dyn Future = set.fs[j];
                            fc.cancel();
                            done[j] = true;
                        }
                        j = j + 1;
                    }
                    (irq_on)();
                    stop = true;
                } else {
                    (wfi)();      // resumes on the pending completion (interrupts still off)
                    (irq_on)();   // take it now: ISR -> async_complete(child); next pass re-polls
                }
            }
        }
    }
    return completed;
}
