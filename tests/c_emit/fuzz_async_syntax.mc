// Phase D, build-order step 3: REAL `async fn` / `await` SYNTAX driven through the Phase-A
// executor. The async transform (src/async_lower.zig) lowers these `async fn`s into stackless
// Future state machines of EXACTLY the shape hand-written in fuzz_async_lowering.mc /
// fuzz_async_cancel_lowering.mc — a struct `f__Fut { state, <child futures>, <captured locals>,
// result }`, an `impl Future` poll that polls children and suspends (`return false`) while pending,
// a `f__Fut_take_result`, a `f__Fut_cancel`, and a `fn f(..)` constructor. This fixture verifies
// the GENERATED code matches the proven results on BOTH backends (entry-mode contract: returns 1
// on success). It exercises:
//   - single await + scalar result;
//   - two awaits in sequence (live local across the 2nd await; async-awaiting-async nesting);
//   - idempotent poll after completion (tail runs exactly once);
//   - LAZY per-state construction: a DEPENDENT await whose call uses an EARLIER await's result
//     (previously REJECTED as E_ASYNC_AWAIT_DEPENDS_ON_PRIOR — now legal);
//   - generated CANCEL: a still-pending future's in-flight leaf slot is reclaimed on drop, and
//     cancel is idempotent (a subsequent poll reports done with no double-free).

import "std/task.mc";

global g_clock: u64 = 0;
fn tick_idle() -> void { g_clock = g_clock + 1; }

// side-effect counter, to prove poll() is idempotent after completion (the tail runs exactly once).
global g_side: u32 = 0;

// ---- leaf future: a mock async value, ready at `deadline`, yielding `val`. Hand-written with the
// uniform child-future ABI the transform consumes for an awaited leaf: a by-value constructor
// `mk_val(..) -> ValFut` (the awaited call), `impl Future for ValFut` (the `ValFut__poll`), a free
// `ValFut_take_result`, AND a free `ValFut_cancel` (the transform now generates a `*_cancel` for
// every async fn, which calls this leaf cancel — so it MUST exist or you get E_UNKNOWN_IDENTIFIER).
//
// A slot counter `g_open` models a held in-flight resource: `mk_val` acquires one; it is released
// EXACTLY ONCE — by the leaf's first completion OR by cancel — guarded by `held`. So a leak (cancel
// not walked to the leaf) or a double-free is observable on BOTH backends. ----
global g_open: i32 = 0;            // live leaf slots; must return to 0
struct ValFut { deadline: u64, val: i32, held: bool }
fn mk_val(deadline: u64, val: i32) -> ValFut {
    var f: ValFut = uninit;
    f.deadline = deadline;
    f.val = val;
    f.held = true;
    g_open = g_open + 1;           // acquire a slot
    return f;
}
impl Future for ValFut {
    fn poll(self: *mut ValFut) -> bool {
        if g_clock >= self.deadline {
            if self.held { self.held = false; g_open = g_open - 1; }   // completion consumes the slot
            return true;
        }
        return false;
    }
}
fn ValFut_take_result(self: *mut ValFut) -> i32 { return self.val; }
fn ValFut_cancel(self: *mut ValFut) -> void {
    if self.held { self.held = false; g_open = g_open - 1; }           // drop releases the slot
}

// ---- single await + scalar result ----
// Lowers to: struct fetch__Fut { state, __c0: ValFut, d, v, result: i32 }; a constructor
// `fn fetch(d,v) -> fetch__Fut`; `impl Future for fetch__Fut { poll }`; `fetch__Fut_take_result`;
// `fetch__Fut_cancel`.
async fn fetch(d: u64, v: i32) -> i32 {
    let r: i32 = await mk_val(d, v);
    return r;
}

// ---- two awaits in sequence; `a` is a live local across the 2nd await -> a STATE FIELD ----
// `await fetch(..)` resolves to the GENERATED `fetch__Fut` future (an async child), exercising
// async-fn-awaiting-async-fn nesting end to end.
async fn sum_two(da: u64, va: i32, db: u64, vb: i32) -> i32 {
    let a: i32 = await fetch(da, va);
    let b: i32 = await fetch(db, vb);
    return a + b;
}

// idempotence: a side-effecting tail statement, so re-polling after completion is observable.
async fn with_side(d: u64) -> i32 {
    let r: i32 = await mk_val(d, 7);
    g_side = g_side + 1;   // tail statement — must run EXACTLY ONCE, not on every later poll
    return r;
}

// ---- LAZY per-state construction: the 2nd await's CALL uses `t`, the 1st await's RESULT ----
// Lowers to: struct chain__Fut { state, __c0: ValFut, __c1: ValFut, d1, v1, d2, t, result }; the
// constructor builds ONLY __c0; __c1 is built at the 0->1 transition (when `t` exists), using
// `t + 1000`. This was previously rejected as E_ASYNC_AWAIT_DEPENDS_ON_PRIOR.
async fn chain(d1: u64, v1: i32, d2: u64) -> i32 {
    let t: i32 = await mk_val(d1, v1);
    let u: i32 = await mk_val(d2, t + 1000);
    return u;
}

// ---- AWAIT INSIDE AN if/else ----
// A pre-branch await (`base`), then ONE bool-if/else each arm of which awaits, then a straight-line
// tail. Only the TAKEN arm's child is ever built (lazy). Lowers to a state machine with per-branch
// state ranges converging on a shared continuation, exactly the shape of fuzz_async_branch_lowering.
// then-path: base(=10)+a(=100)=110; else-path: base(=10)+b(=200)=210.
async fn pick(sel: bool, dt: u64, de: u64) -> i32 {
    let base: i32 = await mk_val(1, 10);
    var out: i32 = 0;
    if sel { let a: i32 = await mk_val(dt, 100); out = base + a; }
    else   { let b: i32 = await mk_val(de, 200); out = base + b; }
    return out;
}

export fn async_syntax_run() -> u32 {
    var acc: u32 = 0;

    // single await + scalar result: ready at tick 3, value 22
    g_clock = 0; g_open = 0;
    var ff: fetch__Fut = fetch(3, 22);
    run_to_completion(&ff, tick_idle);
    if fetch__Fut_take_result(&ff) == 22 { acc = acc ^ 0x1; }

    // two awaits in sequence: a (=10) ready at 3, b (=32) ready at 5 -> 42, completing at tick 5
    g_clock = 0;
    var sf: sum_two__Fut = sum_two(3, 10, 5, 32);
    let ticks: u64 = run_to_completion(&sf, tick_idle);
    if sum_two__Fut_take_result(&sf) == 42 { acc = acc ^ 0x2; }
    if ticks == 5 { acc = acc ^ 0x4; }   // completes only when the LATER await is ready

    // idempotent poll: drive to completion (side effect runs once), then drive AGAIN — a completed
    // future must report done immediately (0 idle ticks: poll returned true on the first call)
    // WITHOUT re-running the tail (g_side stays 1).
    g_clock = 0; g_side = 0;
    var ws: with_side__Fut = with_side(2);
    run_to_completion(&ws, tick_idle);                  // completes; g_side -> 1
    let extra: u64 = run_to_completion(&ws, tick_idle); // re-drive a completed future
    if extra == 0 { acc = acc ^ 0x8; }                  // poll returned true at once (already done)
    if g_side == 1 { acc = acc ^ 0x10; }                // tail ran exactly once (idempotent)

    // LAZY dependent await: t = mk_val(d1=2, v1=5) -> 5; u = mk_val(d2=4, t+1000) -> 1005.
    // If lazy construction works, the 2nd leaf's value reflects the FIRST await's result.
    g_clock = 0; g_open = 0;
    var cf: chain__Fut = chain(2, 5, 4);
    let cticks: u64 = run_to_completion(&cf, tick_idle);
    if chain__Fut_take_result(&cf) == 1005 { acc = acc ^ 0x20; }   // 2nd await saw t=5 -> 1005
    if cticks == 4 { acc = acc ^ 0x40; }                           // completes when the LATER leaf is ready
    if g_open == 0 { acc = acc ^ 0x80; }                           // both leaf slots consumed (no leak)

    // CANCEL a still-pending future: start it, poll twice so it is parked on the 2nd await (the
    // 1st leaf's slot was consumed on completion; the 2nd leaf is in flight, holding one slot), then
    // call the GENERATED cancel. Drive via the generated free fns (UFCS does not resolve on the
    // generated future types). d1=1 (ready@1), d2=100 (never ready in this window).
    g_clock = 0; g_open = 0;
    var xf: chain__Fut = chain(1, 5, 100);
    let q0: bool = chain__Fut__poll(&xf);   // clock 0: 1st leaf pending. g_open=1
    tick_idle();                            // clock 1
    let q1: bool = chain__Fut__poll(&xf);   // clock 1: 1st leaf ready -> release; build & poll 2nd
                                            //          leaf -> acquire; pending. g_open=1
    if !q0 && !q1 { acc = acc ^ 0x100; }    // pending on both polls (not yet complete)
    if g_open == 1 { acc = acc ^ 0x200; }   // exactly one slot held (the 2nd leaf)
    chain__Fut_cancel(&xf);                 // walk the active child (2nd leaf) -> release its slot
    if g_open == 0 { acc = acc ^ 0x400; }   // cancel reclaimed the would-be-leaked slot
    let q2: bool = chain__Fut__poll(&xf);   // a canceled future is DONE: poll true, no slot churn
    if q2 && g_open == 0 { acc = acc ^ 0x800; }  // idempotent: cancel set DONE, no double-free

    // AWAIT-IN-if/else (then branch): sel=true. base ready@1, a ready@3 -> 110, done at tick 3.
    g_clock = 0; g_open = 0;
    var pt: pick__Fut = pick(true, 3, 9);
    run_to_completion(&pt, tick_idle);
    if pick__Fut_take_result(&pt) == 110 { acc = acc ^ 0x1000; }   // base+a = 10+100
    if g_open == 0 { acc = acc ^ 0x2000; }                         // only the then child was built

    // AWAIT-IN-if/else (else branch): sel=false. base ready@1, b ready@5 -> 210, done at tick 5.
    g_clock = 0; g_open = 0;
    var pe: pick__Fut = pick(false, 9, 5);
    run_to_completion(&pe, tick_idle);
    if pick__Fut_take_result(&pe) == 210 { acc = acc ^ 0x4000; }   // base+b = 10+200
    if g_open == 0 { acc = acc ^ 0x8000; }

    // CANCEL mid-branch: take the THEN path, poll past the pre-await so it parks on the then child
    // (one slot held), cancel, prove the slot is reclaimed and a later poll reports done.
    g_clock = 0; g_open = 0;
    var pc: pick__Fut = pick(true, 100, 9);   // then child ready@100 (never in this window)
    let p0: bool = pick__Fut__poll(&pc);      // clock 0: pre-await pending. g_open=1
    tick_idle();                              // clock 1
    let p1: bool = pick__Fut__poll(&pc);      // pre ready -> dispatch then -> build & poll then child -> pending
    if !p0 && !p1 { acc = acc ^ 0x10000; }
    if g_open == 1 { acc = acc ^ 0x20000; }   // one slot held (the then child)
    pick__Fut_cancel(&pc);                    // walk the active then child -> release its slot
    if g_open == 0 { acc = acc ^ 0x40000; }
    let p2: bool = pick__Fut__poll(&pc);      // canceled -> DONE: poll true, no churn
    if p2 && g_open == 0 { acc = acc ^ 0x80000; }

    // entry-mode contract: 1 = pass, 0 = fail.
    if acc != 0xFFFFF { return 0; }
    return 1;
}
