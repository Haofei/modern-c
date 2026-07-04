// Phase D, build-order step 5: the EXACT MC the async-fn -> stackless-state-machine transform
// should GENERATE for an `await` inside a `while` loop. A loop needs a BACK-EDGE (re-evaluate the
// condition after each iteration), which the flat `if self.state == N` fall-through cannot do
// within a single poll — so the generated poll for a loop-bearing async fn is wrapped in
// `while true { <if-state chain> }`: a state block either `return false` (suspend), `return true`
// (done), or sets `state` (possibly BACKWARD, the loop back-edge) and the while re-runs the chain.
// The loop index/condition survive suspension because every local is a captured field.
//
// State layout for `var acc=0; var i=0; while i<n { let v = await e; acc=acc+v; i=i+1; } return acc;`:
//   state 0 (loop head): if `i<n` -> build the iteration's await child, state=1; else state=2.
//   state 1 (loop body): await -> v; acc+=v; i+=1; state=0  (BACK-EDGE to the head).
//   state 2 (continuation/tail): result=acc; state=3 (DONE); return true.
//   state 3: DONE.
// Written by hand as the acceptance target; driving it through the Phase-A executor and diffing
// C vs LLVM proves the loop lowering is identical on both backends.

import "std/task.mc";

global g_clock: u64 = 0;
fn tick_idle() -> void { g_clock = g_clock + 1; }

// cancellable leaf with a slot counter (uniform leaf ABI: __poll + _take_result + _cancel).
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
    fn cancel(self: *mut ValFut) -> void { if self.held { self.held = false; g_open = g_open - 1; } }  // E1
}
fn ValFut_take_result(self: *mut ValFut) -> i32 { return self.val; }
fn ValFut_cancel(self: *mut ValFut) -> void { if self.held { self.held = false; g_open = g_open - 1; } }

// ---- generated for `async fn sumn(n, d) -> i32 {
//        var acc: i32 = 0; var i: i32 = 0;
//        while i < n { let v: i32 = await mk_val(d, i * 10); acc = acc + v; i = i + 1; }
//        return acc; }` ----
struct sumn__Fut { state: u8, __c0: ValFut, n: i32, d: u64, acc: i32, i: i32, v: i32, result: i32 }
fn sumn(n: i32, d: u64) -> sumn__Fut {
    var self: sumn__Fut = .{
        .state = 0,
        .__c0 = uninit,
        .n = n,
        .d = d,
        .acc = 0,
        .i = 0,
        .v = 0,
        .result = 0,
    };
    return self;
}
impl Future for sumn__Fut {
    fn poll(self: *mut sumn__Fut) -> bool {
        while true {
            if self.state == 3 { return true; }            // DONE
            if self.state == 0 {                           // LOOP HEAD: evaluate the condition
                if self.i < self.n {
                    self.__c0 = mk_val(self.d, self.i * 10);   // build this iteration's await child
                    self.state = 1;
                } else {
                    self.state = 2;                        // condition false -> continuation
                }
            }
            if self.state == 1 {                           // LOOP BODY: the await
                let r: bool = ValFut.poll(&self.__c0);
                if !r { return false; }                    // suspend (loop index/acc preserved in fields)
                self.v = ValFut_take_result(&self.__c0);
                self.acc = self.acc + self.v;
                self.i = self.i + 1;
                self.state = 0;                            // BACK-EDGE to the loop head
            }
            if self.state == 2 {                           // continuation / tail
                self.result = self.acc;
                self.state = 3;
                return true;
            }
        }
        return false;   // unreachable (the while-true only exits via an inner return), but the
                        // return checker doesn't special-case `while true` — keep it satisfied.
    }
    fn cancel(self: *mut sumn__Fut) -> void { sumn__Fut_cancel(self); }   // E1
}
fn sumn__Fut_take_result(self: *mut sumn__Fut) -> i32 { return self.result; }
// cancel: only state 1 holds a live child (the in-flight iteration await).
fn sumn__Fut_cancel(self: *mut sumn__Fut) -> void {
    if self.state == 1 { ValFut_cancel(&self.__c0); }
    self.state = 3;
}

export fn async_loop_lowering_run() -> u32 {
    var acc: u32 = 0;

    // (1) loop runs 3 iterations: v = 0,10,20 -> sum 30. Each await ready at deadline 1, so the
    // first poll suspends at clock 0; once clock reaches 1 the while-true drives ALL remaining
    // iterations in a single poll -> exactly 1 idle tick.
    g_clock = 0; g_open = 0;
    var f1: sumn__Fut = sumn(3, 1);
    let t1: u64 = run_to_completion(&f1, tick_idle);
    if sumn__Fut_take_result(&f1) == 30 { acc = acc ^ 0x1; }
    if t1 == 1 { acc = acc ^ 0x2; }
    if g_open == 0 { acc = acc ^ 0x4; }            // every iteration's slot consumed (no leak)

    // (2) zero-iteration loop: n=0 -> condition false immediately -> result 0, no await, no idle.
    g_clock = 0; g_open = 0;
    var f0: sumn__Fut = sumn(0, 1);
    let t0: u64 = run_to_completion(&f0, tick_idle);
    if sumn__Fut_take_result(&f0) == 0 { acc = acc ^ 0x8; }
    if t0 == 0 { acc = acc ^ 0x10; }               // completed on the first poll (no suspension)
    if g_open == 0 { acc = acc ^ 0x20; }           // no child ever built

    // (3) cancel mid-loop: a long deadline keeps the iteration await pending; poll once to park on
    // it (one slot held), cancel, prove the slot is reclaimed and poll is idempotent.
    g_clock = 0; g_open = 0;
    var fc: sumn__Fut = sumn(5, 100);              // await ready@100 (won't, in this window)
    let c0: bool = sumn__Fut.poll(&fc);            // head: i=0<5 -> build child; body: pending -> false
    if !c0 && g_open == 1 { acc = acc ^ 0x40; }    // parked on the iteration await, one slot held
    sumn__Fut_cancel(&fc);                         // walk the active child -> release its slot
    if g_open == 0 { acc = acc ^ 0x80; }
    let c1: bool = sumn__Fut.poll(&fc);            // canceled -> DONE: poll true, no churn
    if c1 && g_open == 0 { acc = acc ^ 0x100; }

    if acc != 0x1FF { return 0; }
    return 1;
}
