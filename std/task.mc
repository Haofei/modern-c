// std/task.mc — pure async TASK VOCABULARY (async/await roadmap, Phase A).
//
// This module is PURE: it knows nothing about ProcTable, IRQs, wait queues, broker slots,
// or syscalls — only how to *poll* and *compose* futures. The scheduler / broker / park-wake
// integration lives in the kernel (kernel/lib/async.mc, Phase B); the IRQ-backed completion
// path is Phase C; `async`/`await` syntax (a stackless state-machine transform) is the
// optional Phase D. Everything here is FIXED-SIZE with no hidden heap.
//
// Model. A `Future` is anything that can be polled to advance; `poll` returns `true` once the
// future is COMPLETE and must keep returning `true` afterward (idempotent). `poll` MUST NOT
// block — the executor owns the wait/park policy. A typed leaf future stores its own result
// and exposes it as `?T` after completion ("Poll<T>" by convention: `null` = pending, a value
// = ready); the bool-returning `poll` is what drives the executor and the combinators. A
// generic-over-T `poll` return is intentionally avoided: MC has no generic tagged unions, and
// a type-erased generic result would force heap or unsafe punning, against the no-hidden-heap
// rule. Typed results are therefore read from the concrete future, not threaded through poll.
//
// Combinators (join2 / race2 / timeout) are themselves `Future`s over `*mut dyn Future`
// children, so they nest. `*dyn` dispatch is excluded from `#[irq_context]`/`#[bounded]`, so
// this vocabulary is for task/agent context, never an ISR.

// The core abstraction. `poll` advances the future and returns true once complete; `cancel`
// drops a still-pending future, releasing any in-flight resource it holds (a broker slot, a child
// future). `cancel` MUST be idempotent and a no-op once the future is complete — after a winner is
// decided a combinator cancels the type-erased LOSER through this vtable slot (E1). `*dyn` dispatch
// is excluded from `#[irq_context]`/`#[bounded]`, so this vocabulary is task/agent context only.
trait Future {
    fn poll(self: *mut Self) -> bool;
    fn cancel(self: *mut Self) -> void;
}

// ---- leaf: a request id mapped to a pending future (the broker seam, kept pure) ----
//
// `SlotFuture` is the shape "a submitted request id maps to a pending future". It stays pure
// by INJECTING the completion source as `done(id) -> bool`: std never learns what the source
// is (the kernel supplies a `done` backed by the vectored SYS_POLL / inflight table in Phase
// B). Fixed-size — one per in-flight request — so callers keep the live count <= MAX_INFLIGHT.
//
// Cancellation is ALSO injected, as `cancel(id) -> void` (the kernel supplies one backed by
// `async_cancel`, which frees the inflight slot). `slot_future_cancel` is what a generated
// `async fn`'s `cancel` walks down to when this is the leaf still in flight: dropping a pending
// future must release its broker slot, or it leaks (see kernel/lib/async.mc `async_cancel`).
// `cancel` is only meaningful while pending — once `ready`, the slot is already consumed.
struct SlotFuture {
    id: u64,
    done: fn(u64) -> bool,
    cancel: fn(u64) -> void,
    ready: bool,
}

#[mc_abi]
export fn slot_future_init(s: *mut SlotFuture, id: u64, done: fn(u64) -> bool, cancel: fn(u64) -> void) -> void {
    s.id = id;
    s.done = done;
    s.cancel = cancel;
    s.ready = false;
}

impl Future for SlotFuture {
    fn poll(self: *mut SlotFuture) -> bool {
        if self.ready { return true; }
        self.ready = (self.done)(self.id);
        return self.ready;
    }
    // Cancel a still-pending SlotFuture: release its in-flight slot via the INJECTED `cancel`
    // function pointer (the struct field, also named `cancel` — `self.cancel` reads the field, the
    // method is reached via the vtable). No-op once `ready` (its slot was already consumed by
    // completion). Idempotent: after a cancel the caller must not poll/take_result this future again.
    fn cancel(self: *mut SlotFuture) -> void {
        if self.ready { return; }
        (self.cancel)(self.id);
    }
}

// Free-function alias kept for callers that hold a concrete SlotFuture; mirrors the trait method.
export fn slot_future_cancel(s: *mut SlotFuture) -> void {
    if s.ready { return; }
    (s.cancel)(s.id);
}

// ---- combinator: join2 — complete when BOTH children complete ----
//
// Each child is latched once it reports done, so a completed child is never polled again.
struct Join2 {
    a: *mut dyn Future,
    b: *mut dyn Future,
    ad: bool,
    bd: bool,
}

#[mc_abi]
export fn join2_init(j: *mut Join2, a: *mut dyn Future, b: *mut dyn Future) -> void {
    j.a = a;
    j.b = b;
    j.ad = false;
    j.bd = false;
}

impl Future for Join2 {
    fn poll(self: *mut Join2) -> bool {
        if !self.ad { self.ad = self.a.poll(); }
        if !self.bd { self.bd = self.b.poll(); }
        return self.ad && self.bd;
    }
    // Drop both children through the vtable. Each child's own `cancel` is a no-op if already
    // complete, so cancelling a partially-done join only releases the still-pending arm.
    fn cancel(self: *mut Join2) -> void {
        self.a.cancel();
        self.b.cancel();
    }
}

// ---- combinator: race2 — complete when EITHER child completes ----
//
// `winner` records which finished first (0 = a, 1 = b; -1 while undecided). When a winner is
// decided, the type-erased LOSER is CANCELLED through the `Future` vtable (E1: `cancel` is now a
// trait method), so the loser's in-flight resource — e.g. a broker MAX_INFLIGHT slot — is reclaimed
// rather than leaked. This is the cancellation-dependent agent primitive: "race two tool calls,
// cancel the loser" (timeout is the same shape — race the op against a deadline future).
struct Race2 {
    a: *mut dyn Future,
    b: *mut dyn Future,
    winner: i32,
}

#[mc_abi]
export fn race2_init(r: *mut Race2, a: *mut dyn Future, b: *mut dyn Future) -> void {
    r.a = a;
    r.b = b;
    r.winner = -1;
}

export fn race2_winner(r: *Race2) -> i32 {
    return r.winner;
}

impl Future for Race2 {
    fn poll(self: *mut Race2) -> bool {
        // A `*dyn` dispatch call used DIRECTLY as an if-condition whose body terminates now lowers
        // on BOTH backends (the LLVM backend previously needed the result hoisted into a local; that
        // gap is fixed — callReturnType resolves a dispatch call's type, so the if/switch subject
        // lowers). No hoist needed.
        if self.winner >= 0 { return true; }
        if self.a.poll() { self.winner = 0; self.b.cancel(); return true; }
        if self.b.poll() { self.winner = 1; self.a.cancel(); return true; }
        return false;
    }
    // Drop the race (no winner yet, or to abandon it): cancel BOTH children. Idempotent — the
    // already-decided winner is `ready` so its `cancel` is a no-op, and the loser was cancelled in
    // `poll`, so re-cancelling here is harmless.
    fn cancel(self: *mut Race2) -> void {
        self.a.cancel();
        self.b.cancel();
    }
}

// ---- combinator: timeout — complete when the inner future completes OR the budget elapses ----
//
// Phase A counts POLL TICKS (deterministic, no clock dependency); Phase B can swap the budget
// for a real deadline driven by a timer future. `timed_out` records which arm fired.
struct Timeout {
    inner: *mut dyn Future,
    remaining: u64,
    timed_out: bool,
    done: bool,
}

#[mc_abi]
export fn timeout_init(t: *mut Timeout, inner: *mut dyn Future, budget_ticks: u64) -> void {
    t.inner = inner;
    t.remaining = budget_ticks;
    t.timed_out = false;
    t.done = false;
}

export fn timeout_timed_out(t: *Timeout) -> bool {
    return t.timed_out;
}

impl Future for Timeout {
    fn poll(self: *mut Timeout) -> bool {
        if self.done { return true; }
        // direct `*dyn` dispatch as the if-condition — lowers on both backends (see Race2::poll).
        if self.inner.poll() {
            self.done = true;
            return true;
        }
        if self.remaining == 0 {
            self.timed_out = true;
            self.done = true;
            self.inner.cancel();   // budget elapsed: drop the still-pending inner, free its slot
            return true;
        }
        self.remaining = self.remaining - 1;
        return false;
    }
    // Drop the timeout: cancel the inner future. No-op if inner already completed (its `cancel`
    // is idempotent); harmless on the timed-out path where `poll` already cancelled it.
    fn cancel(self: *mut Timeout) -> void {
        self.inner.cancel();
    }
}

// ---- executor ----
//
// Drive one future to completion, invoking `idle` after each poll that did not complete it.
// In Phase A `idle` is a yield/step hook; in Phase B it becomes park-on-wait-queue / `wfi`,
// so the executor sleeps instead of spinning. Returns the number of idle ticks spent waiting
// — a smoke-test observable. There is no internal iteration cap: a stuck leaf must be bounded
// by a `Timeout` combinator, not by a hidden limit here.
#[mc_abi]
export fn run_to_completion(f: *mut dyn Future, idle: fn() -> void) -> u64 {
    var ticks: u64 = 0;
    while !f.poll() {
        (idle)();
        ticks = ticks + 1;
    }
    return ticks;
}

// NOTE: the vectored drain (advance many in-flight futures per scheduler wakeup, mirroring
// the broker's `SYS_POLL(events, max)`) is intentionally NOT here. In pure std it would mean
// pointer arithmetic over an array of `*mut dyn` fat pointers; in practice the drain iterates
// the kernel's fixed inflight-slot TABLE, which knows the slot type and bound (MAX_INFLIGHT).
// So `poll_many` lives in kernel/lib/async.mc (Phase B), over the inflight table, not here.
