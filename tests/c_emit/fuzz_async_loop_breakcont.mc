// Phase E step E3b: `break` / `continue` INSIDE an await-bearing while-loop body.
// Until E3b, collectLoopBody REJECTED break/continue (E_ASYNC_LOOP_UNSUPPORTED). E3b lowers them as
// state-jump edges that re-enter the `while true` poll wrapper:
//   `break`    -> `self.state = cont_state; continue;`  (exit the loop -> continuation/tail)
//   `continue` -> `self.state = 0; continue;`           (loop-head state: re-check the condition)
// The emitted `continue;` re-enters the while-true, which checks DONE then dispatches on the NEW
// state — modelling the source edge exactly while skipping the rest of the body block + back-edge.
//
// Soundness (at-most-one-child-live + cancel-on-exit): break/continue live in the body's
// straight-line code, which runs AFTER the body await took its result, so NO child is live at the
// edge. `continue` re-enters the loop head, which rebuilds __c0 exactly ONCE per entry; `break`
// builds no child. So no leak, no double-build across the back-edge/exit edge. The mid-flight child
// of a still-SUSPENDED await (the future dropped while parked) is still freed by the generated
// cancel — proven by the cancel-mid-loop check below.
//
// Entry-mode contract: returns 1 iff every check passes; both backends must agree.

import "std/task.mc";

global g_clock: u64 = 0;
fn tick_idle() -> void { g_clock = g_clock + 1; }

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

// ---- BREAK inside an await-bearing loop body ----
// Sum v=i*10 across iterations, but BREAK out when the accumulator reaches/exceeds `cap`. After the
// break the loop exits to the tail, which returns `acc`. n large so break (not n) ends the loop.
async fn loop_break(n: i32, d: u64, cap: i32) -> i32 {
    var acc: i32 = 0;
    var i: i32 = 0;
    while i < n {
        let v: i32 = await mk_val(d, i * 10);
        acc = acc + v;
        if acc >= cap { break; }     // BREAK out of the await-bearing loop
        i = i + 1;
    }
    return acc;
}

// ---- CONTINUE inside an await-bearing loop body ----
// Sum v=i*10 but SKIP adding when v is in a band (here: skip i==1). `continue` jumps back to the
// loop head (re-checking `i < n`), so `i` must be advanced BEFORE the continue or it would spin.
async fn loop_continue(n: i32, d: u64) -> i32 {
    var acc: i32 = 0;
    var i: i32 = 0;
    while i < n {
        let v: i32 = await mk_val(d, i * 10);
        i = i + 1;                    // advance BEFORE continue (else infinite loop)
        if v == 10 { continue; }      // skip adding v==10 (the i==1 iteration)
        acc = acc + v;
    }
    return acc;
}

// ---- IF-LET inside an await-bearing loop body ----
// After the loop-body await is taken, the body tail contains an `if let` narrowing. The loop-body
// rewriter must rewrite captured reads in the matched value and both arms while keeping the payload
// binding local to the then arm.
async fn loop_iflet(n: i32, d: u64, maybe: ?*mut i32) -> i32 {
    var acc: i32 = 0;
    var i: i32 = 0;
    while i < n {
        let v: i32 = await mk_val(d, i * 10);
        if let p = maybe {
            acc = acc + v + *p;
        } else {
            acc = acc + v;
        }
        i = i + 1;
    }
    return acc;
}

export fn async_loop_breakcont_run() -> u32 {
    var acc: u32 = 0;

    // BREAK: n=10, cap=30, v=0,10,20,30,... acc=0,10,30 -> >=30 at i=2 (v=20): wait, recompute:
    //   i=0 v=0  acc=0  (0<30, i->1)
    //   i=1 v=10 acc=10 (10<30, i->2)
    //   i=2 v=20 acc=30 (30>=30 -> BREAK before i++). result 30.
    g_clock = 0; g_open = 0;
    var lb: loop_break__Fut = loop_break(10, 1, 30);
    run_to_completion(&lb, tick_idle);
    if loop_break__Fut_take_result(&lb) == 30 { acc = acc ^ 0x1; }
    if g_open == 0 { acc = acc ^ 0x2; }                    // every consumed slot released; no leak

    // BREAK never fires (cap huge): n=3 -> 0+10+20 = 30 via normal loop exit.
    g_clock = 0; g_open = 0;
    var lbn: loop_break__Fut = loop_break(3, 1, 100000);
    run_to_completion(&lbn, tick_idle);
    if loop_break__Fut_take_result(&lbn) == 30 { acc = acc ^ 0x4; }
    if g_open == 0 { acc = acc ^ 0x8; }

    // CONTINUE: n=4, v=0,10,20,30. skip v==10 (i=1). sum = 0+20+30 = 50.
    g_clock = 0; g_open = 0;
    var lc: loop_continue__Fut = loop_continue(4, 1);
    run_to_completion(&lc, tick_idle);
    if loop_continue__Fut_take_result(&lc) == 50 { acc = acc ^ 0x10; }
    if g_open == 0 { acc = acc ^ 0x20; }                   // every iteration slot consumed (incl skipped)

    // CANCEL mid-loop (parked on the body await, before any break/continue): long deadline keeps the
    // await pending; poll once to park (one slot held), cancel, prove no leak / double-free.
    g_clock = 0; g_open = 0;
    var lk: loop_break__Fut = loop_break(10, 100, 30);     // await ready@100 (never in window)
    let k0: bool = loop_break__Fut__poll(&lk);             // head builds child; body await pending
    if !k0 && g_open == 1 { acc = acc ^ 0x40; }
    loop_break__Fut_cancel(&lk);                           // free the in-flight child
    if g_open == 0 { acc = acc ^ 0x80; }
    let k1: bool = loop_break__Fut__poll(&lk);             // canceled -> DONE, no churn
    if k1 && g_open == 0 { acc = acc ^ 0x100; }

    // IF-LET present: n=3, v=0,10,20 plus payload 3 each iter -> 39.
    g_clock = 0; g_open = 0;
    var bonus: i32 = 3;
    var li: loop_iflet__Fut = loop_iflet(3, 1, &bonus);
    run_to_completion(&li, tick_idle);
    if loop_iflet__Fut_take_result(&li) == 39 { acc = acc ^ 0x200; }
    if g_open == 0 { acc = acc ^ 0x400; }

    // IF-LET absent: same loop without payload -> 0+10+20 = 30.
    g_clock = 0; g_open = 0;
    var ln: loop_iflet__Fut = loop_iflet(3, 1, null);
    run_to_completion(&ln, tick_idle);
    if loop_iflet__Fut_take_result(&ln) == 30 { acc = acc ^ 0x800; }
    if g_open == 0 { acc = acc ^ 0x1000; }

    if acc != 0x1FFF { return 0; }
    return 1;
}
