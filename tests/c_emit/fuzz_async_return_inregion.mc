// Phase E step E3a: a `return v` INSIDE an await-bearing loop body OR if/else arm.
// Until E3a, `collectLoopBody`/`collectArm` REJECTED any `return` in an await-bearing region
// (E_ASYNC_LOOP_UNSUPPORTED / E_ASYNC_BRANCH_UNSUPPORTED) — the region had to fall through to the
// shared continuation/back-edge. E3a lowers a `return v` (top-level OR nested in non-await control
// flow within the region) to the terminal DONE transition: `self.result = v; self.state = DONE;
// return true;` — exactly the tail's `return` lowering, but reachable from inside a loop/arm.
//
// Soundness (at-most-one-child-live + cancel-on-exit): a `return` lives in a region's straight-line
// code, which runs AFTER that region's await took its result — so NO child is live at the return.
// Setting state=DONE is therefore a clean exit; a subsequent cancel finds DONE (no active child, no
// double-free) and a subsequent poll early-returns true. The MID-FLIGHT child of a still-SUSPENDED
// await (the future dropped while parked, NOT at a return) is still freed by the generated cancel.
//
// Entry-mode contract: returns 1 iff every check passes; both backends must agree.

import "std/task.mc";

global g_clock: u64 = 0;
fn tick_idle() -> void { g_clock = g_clock + 1; }

// Leaf future with a held-slot resource (leak / double-free detector), same ABI as fuzz_async_syntax.
global g_open: i32 = 0;
struct ValFut { deadline: u64, val: i32, held: bool }
fn mk_val(deadline: u64, val: i32) -> ValFut {
    g_open = g_open + 1;
    return .{ .deadline = deadline, .val = val, .held = true };
}
impl Future for ValFut {
    fn poll(self: *mut ValFut) -> bool {
        if g_clock >= self.deadline {
            if self.held { self.held = false; g_open = g_open - 1; }
            return true;
        }
        return false;
    }
    fn cancel(self: *mut ValFut) -> void {
        if self.held { self.held = false; g_open = g_open - 1; }
    }
}
fn ValFut_take_result(self: *mut ValFut) -> i32 { return self.val; }
fn ValFut_cancel(self: *mut ValFut) -> void {
    if self.held { self.held = false; g_open = g_open - 1; }
}

// ---- RETURN inside a while-loop body (conditional early exit) ----
// Accumulate v across iterations; if the running sum reaches/exceeds `cap`, return EARLY from inside
// the loop. Each await yields i*10. n large, cap small => the early return fires mid-loop.
async fn loop_return(n: i32, d: u64, cap: i32) -> i32 {
    var acc: i32 = 0;
    var i: i32 = 0;
    while i < n {
        let v: i32 = await mk_val(d, i * 10);
        acc = acc + v;
        if acc >= cap { return acc; }   // EARLY return from inside an await-bearing loop
        i = i + 1;
    }
    return acc;   // normal loop-exit return (the continuation/tail)
}

// ---- RETURN inside an if/else arm ----
// then-arm awaits then RETURNS its value directly (no fall-through to a shared continuation);
// else-arm awaits, falls through to the tail.
async fn arm_return(sel: bool, dt: u64, de: u64) -> i32 {
    let base: i32 = await mk_val(1, 10);
    if sel {
        let a: i32 = await mk_val(dt, 100);
        return base + a;            // RETURN from inside the then arm
    } else {
        let b: i32 = await mk_val(de, 200);
        return base + b;            // RETURN from inside the else arm
    }
}

export fn async_return_inregion_run() -> u32 {
    var acc: u32 = 0;

    // loop early-return: n=10, cap=30, v = 0,10,20,30,... acc after each: 0,10,30 -> >=30 at i=2,
    // return 30 mid-loop (does NOT run all 10 iterations). all awaits ready@1.
    g_clock = 0; g_open = 0;
    var lr: loop_return__Fut = loop_return(10, 1, 30);
    run_to_completion(&lr, tick_idle);
    if loop_return__Fut_take_result(&lr) == 30 { acc = acc ^ 0x1; }
    if g_open == 0 { acc = acc ^ 0x2; }                 // every consumed slot released; no leak

    // loop normal-exit return: cap huge => never early-returns; n=3 -> 0+10+20 = 30 via the tail.
    g_clock = 0; g_open = 0;
    var ln: loop_return__Fut = loop_return(3, 1, 100000);
    run_to_completion(&ln, tick_idle);
    if loop_return__Fut_take_result(&ln) == 30 { acc = acc ^ 0x4; }
    if g_open == 0 { acc = acc ^ 0x8; }

    // arm return (then): sel=true -> base(10)+a(100) = 110 returned from inside the arm.
    g_clock = 0; g_open = 0;
    var at: arm_return__Fut = arm_return(true, 3, 9);
    run_to_completion(&at, tick_idle);
    if arm_return__Fut_take_result(&at) == 110 { acc = acc ^ 0x10; }
    if g_open == 0 { acc = acc ^ 0x20; }

    // arm return (else): sel=false -> base(10)+b(200) = 210 returned from inside the arm.
    g_clock = 0; g_open = 0;
    var ae: arm_return__Fut = arm_return(false, 9, 5);
    run_to_completion(&ae, tick_idle);
    if arm_return__Fut_take_result(&ae) == 210 { acc = acc ^ 0x40; }
    if g_open == 0 { acc = acc ^ 0x80; }

    // CANCEL mid-loop BEFORE the early return fires: long deadline keeps the iteration await pending,
    // poll once to park on it (one slot held), cancel the in-flight child, prove no leak/double-free.
    g_clock = 0; g_open = 0;
    var lc: loop_return__Fut = loop_return(10, 100, 30);   // await ready@100 (never in window)
    let c0: bool = loop_return__Fut__poll(&lc);            // head: build child; body await pending
    if !c0 && g_open == 1 { acc = acc ^ 0x100; }
    loop_return__Fut_cancel(&lc);                          // free the in-flight child
    if g_open == 0 { acc = acc ^ 0x200; }
    let c1: bool = loop_return__Fut__poll(&lc);            // canceled -> DONE, no churn
    if c1 && g_open == 0 { acc = acc ^ 0x400; }

    if acc != 0x7FF { return 0; }
    return 1;
}
