// Phase E step E3c: an `await` NESTED inside an `if` inside a `while` (the headline general-CFG case).
// Until E3c the flat per-construct state allocator rejected this (bad/async_loop_nested_await.mc,
// E_ASYNC_LOOP_UNSUPPORTED): an interior suspend point reached only on the `if`-true path could not be
// numbered. E3c lowers the whole async-fn body as a structured CFG over ONE `while true { switch state }`
// dispatch: every `await` is its own poll-state, its child is materialized on the ENTRY EDGE (the
// predecessor block) immediately before the `goto`, and the poll-state itself NEVER rebuilds — so a
// re-poll (re-entering the same state through the while-true) does not re-issue the awaited side effect,
// and a loop back-edge that re-runs the head rebuilds `__c0` exactly once per iteration.
//
// Soundness probed here:
//   * at-most-one-child-live: every leaf holds a slot while pending; g_open is the live-slot counter.
//     The inner await (state B) is built only on the if-true edge, after the outer await (state A) took
//     its result — so A's child is dead before B's is built; never two live.
//   * build-once-per-entry: if the nested child were rebuilt on re-poll, mk_val would bump g_open twice
//     and the slot accounting would never return to 0. The cancel-mid-nested-flight checks below PARK on
//     the inner await and assert exactly one live slot, then cancel to exactly zero — a double-build or a
//     two-children-live bug cannot reach g_open==0 here.
//
// Entry-mode contract: returns 1 iff every check passes; both backends must agree.

import "std/task.mc";

global g_clock: u64 = 0;
fn tick_idle() -> void { g_clock = g_clock + 1; }

// Leaf future with a held-slot resource (leak / double-free / double-build detector).
global g_open: i32 = 0;
global g_built: i32 = 0;                  // total mk_val calls — a build-twice bug bumps this extra
struct ValFut { deadline: u64, val: i32, held: bool }
fn mk_val(deadline: u64, val: i32) -> ValFut {
    g_open = g_open + 1;
    g_built = g_built + 1;
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

// ---- await NESTED in an `if` INSIDE a `while` ----
// Outer await yields a=i*10 each iteration. When a>0 (i.e. i>0) a SECOND await (nested in the if) yields
// b=a*2 and adds it; otherwise only a is added. i advances after the if (the join), back-edge to head.
//   i=0: a=0   (a>0 false)            acc += 0           -> 0
//   i=1: a=10  (a>0)  b=20  acc+=20   acc += 10          -> 30
//   i=2: a=20  (a>0)  b=40  acc+=40   acc += 20          -> 90
//   i=3: a=30  (a>0)  b=60  acc+=60   acc += 30          -> 180
async fn nested(n: i32, d: u64) -> i32 {
    var acc: i32 = 0;
    var i: i32 = 0;
    while i < n {
        let a: i32 = await mk_val(d, i * 10);
        if a > 0 {
            let b: i32 = await mk_val(d, a * 2);   // await NESTED in an inner `if`, inside the `while`
            acc = acc + b;
        }
        acc = acc + a;                              // the join: runs on BOTH if-paths
        i = i + 1;
    }
    return acc;
}

export fn async_nested_await_run() -> u32 {
    var acc: u32 = 0;

    // n=4, d=1 (all ready immediately): result 180, every slot released, no double-build.
    g_clock = 0; g_open = 0; g_built = 0;
    var f: nested__Fut = nested(4, 1);
    run_to_completion(&f, tick_idle);
    if nested__Fut_take_result(&f) == 180 { acc = acc ^ 0x1; }
    if g_open == 0 { acc = acc ^ 0x2; }                       // no leak
    // exactly one mk_val per await actually reached: i=0 -> 1 (outer only); i=1,2,3 -> 2 each = 7 total.
    if g_built == 7 { acc = acc ^ 0x4; }                      // no build-twice

    // n=1: only i=0, a=0, the nested if-arm is NOT taken (a>0 false) -> result 0, one build (outer only).
    g_clock = 0; g_open = 0; g_built = 0;
    var f1: nested__Fut = nested(1, 1);
    run_to_completion(&f1, tick_idle);
    if nested__Fut_take_result(&f1) == 0 { acc = acc ^ 0x8; }
    if g_open == 0 { acc = acc ^ 0x10; }
    if g_built == 1 { acc = acc ^ 0x20; }                     // inner arm never built its child

    // CANCEL parked on the OUTER await (state A), before the inner if: long deadline keeps it pending.
    g_clock = 0; g_open = 0; g_built = 0;
    var fa: nested__Fut = nested(4, 100);                     // ready@100, never in window
    let a0: bool = nested__Fut__poll(&fa);                    // head builds outer child; parks on it
    if !a0 && g_open == 1 && g_built == 1 { acc = acc ^ 0x40; }
    nested__Fut_cancel(&fa);                                  // free the in-flight OUTER child
    if g_open == 0 { acc = acc ^ 0x80; }
    let a1: bool = nested__Fut__poll(&fa);                    // canceled -> DONE, no churn
    if a1 && g_open == 0 && g_built == 1 { acc = acc ^ 0x100; }

    // CANCEL parked on the INNER (nested) await (state B): let the OUTER await resolve, then park on the
    // inner one (the if-true path, i>=1). A leaf is ready when g_clock >= its deadline; set the clock to
    // 1 so the OUTER (deadline 1) resolves on poll but the INNER (deadline 50) parks.
    g_clock = 1; g_open = 0; g_built = 0;
    var fb: nested_split__Fut = nested_split(2, 1, 50);      // outer ready@<=1, inner ready@50
    // one poll drives: head i=0 build outer(1) ready a=0 (no inner); back-edge; head i=1 build outer(2)
    // ready a=10>0 build inner(3) park (clock 1 < 50). The two outer children were consumed; inner live.
    let b0: bool = nested_split__Fut__poll(&fb);
    if !b0 && g_open == 1 { acc = acc ^ 0x200; }              // exactly ONE live child (the inner one)
    if g_built == 3 { acc = acc ^ 0x400; }                   // i=0 outer(1) + i=1 outer(1) + i=1 inner(1)
    nested_split__Fut_cancel(&fb);                            // free the in-flight INNER child
    if g_open == 0 { acc = acc ^ 0x800; }                    // no leak, no double-free
    let b1: bool = nested_split__Fut__poll(&fb);             // canceled -> DONE
    if b1 && g_open == 0 { acc = acc ^ 0x1000; }

    if acc != 0x1FFF { return 0; }
    return 1;
}

// A variant with SEPARATE outer/inner deadlines so a cancel can park precisely on the inner await.
async fn nested_split(n: i32, dout: u64, din: u64) -> i32 {
    var acc: i32 = 0;
    var i: i32 = 0;
    while i < n {
        let a: i32 = await mk_val(dout, i * 10);
        if a > 0 {
            let b: i32 = await mk_val(din, a * 2);
            acc = acc + b;
        }
        acc = acc + a;
        i = i + 1;
    }
    return acc;
}
