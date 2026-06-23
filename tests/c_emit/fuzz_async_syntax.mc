// Phase D, build-order step 3: REAL `async fn` / `await` SYNTAX driven through the Phase-A
// executor. The async transform (src/async_lower.zig) lowers these `async fn`s into stackless
// Future state machines of EXACTLY the shape hand-written in fuzz_async_lowering.mc — a struct
// `f__Fut { state, <child futures>, <captured locals>, result }`, an `impl Future` poll that polls
// children and suspends (`return false`) while pending, a `f__Fut_take_result`, and a `fn f(..)`
// constructor. This fixture verifies the GENERATED code matches the proven results on BOTH backends
// (entry-mode contract: returns 1 on success). It mirrors fuzz_async_lowering.mc's scenarios:
// single await + scalar result, and two awaits in sequence with a live local across the 2nd await.

import "std/task.mc";

global g_clock: u64 = 0;
fn tick_idle() -> void { g_clock = g_clock + 1; }

// ---- leaf future: a mock async value, ready at `deadline`, yielding `val`. Hand-written with
// the uniform child-future ABI the transform consumes for an awaited leaf:
//   - a by-value constructor `mk_val(deadline, val) -> ValFut` (the awaited call `await mk_val(..)`)
//   - `impl Future for ValFut` (the `ValFut__poll` the transform calls)
//   - a free `ValFut_take_result(self) -> i32` (valid once, after poll()==true). ----
struct ValFut { deadline: u64, val: i32 }
fn mk_val(deadline: u64, val: i32) -> ValFut {
    var f: ValFut = uninit;
    f.deadline = deadline;
    f.val = val;
    return f;
}
impl Future for ValFut {
    fn poll(self: *mut ValFut) -> bool { return g_clock >= self.deadline; }
}
fn ValFut_take_result(self: *mut ValFut) -> i32 { return self.val; }

// ---- single await + scalar result ----
// Lowers to: struct fetch__Fut { state, __c0: ValFut, d, v, result: i32 }; a constructor
// `fn fetch(d,v) -> fetch__Fut`; `impl Future for fetch__Fut { poll }`; `fetch__Fut_take_result`.
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

export fn async_syntax_run() -> u32 {
    var acc: u32 = 0;

    // single await + scalar result: ready at tick 3, value 22
    g_clock = 0;
    var ff: fetch__Fut = fetch(3, 22);
    run_to_completion(&ff, tick_idle);
    if fetch__Fut_take_result(&ff) == 22 { acc = acc ^ 0x1; }

    // two awaits in sequence: a (=10) ready at 3, b (=32) ready at 5 -> 42, completing at tick 5
    g_clock = 0;
    var sf: sum_two__Fut = sum_two(3, 10, 5, 32);
    let ticks: u64 = run_to_completion(&sf, tick_idle);
    if sum_two__Fut_take_result(&sf) == 42 { acc = acc ^ 0x2; }
    if ticks == 5 { acc = acc ^ 0x4; }   // completes only when the LATER await is ready

    // entry-mode contract: 1 = pass, 0 = fail.
    if acc != 0x7 { return 0; }
    return 1;
}
