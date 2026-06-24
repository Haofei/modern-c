// Phase D follow-up: UFCS on a GENERATED future. The transform now rewrites `f__Fut.poll(&x)` (a
// method-call on a transform-generated future type) to the mangled free fn `f__Fut__poll`, the same
// way the parser resolves hand-written `Type.method(..)`. Previously this did not resolve (the
// generated type does not exist at parse time), so callers had to use the free fn `f__Fut__poll`.
// This fixture drives a generated future BOTH ways and asserts they agree on both backends.

import "std/task.mc";

global g_clock: u64 = 0;
fn tick_idle() -> void { g_clock = g_clock + 1; }

struct ValFut { deadline: u64, val: i32 }
fn mk_val(deadline: u64, val: i32) -> ValFut {
    var f: ValFut = uninit;
    f.deadline = deadline;
    f.val = val;
    return f;
}
impl Future for ValFut {
    fn poll(self: *mut ValFut) -> bool { return g_clock >= self.deadline; }
    fn cancel(self: *mut ValFut) -> void { self.val = 0; }   // E1: leaf cancel (no real slot here)
}
fn ValFut_take_result(self: *mut ValFut) -> i32 { return self.val; }
fn ValFut_cancel(self: *mut ValFut) -> void { self.val = 0; }   // (uses self; cancel unused in this run)

async fn fetch(d: u64, v: i32) -> i32 {
    let r: i32 = await mk_val(d, v);
    return r;
}

export fn async_ufcs_run() -> u32 {
    var acc: u32 = 0;

    // Drive a generated `fetch__Fut` via UFCS `fetch__Fut.poll(&ff)` (the new sugar), hand-stepping
    // the state machine: ready at tick 2, value 21.
    g_clock = 0;
    var ff: fetch__Fut = fetch(2, 21);
    let p0: bool = fetch__Fut.poll(&ff);     // clock 0: child pending -> false
    tick_idle(); tick_idle();                 // clock 2
    let p1: bool = fetch__Fut.poll(&ff);     // child ready -> completes -> true
    if !p0 && p1 && fetch__Fut_take_result(&ff) == 21 { acc = acc ^ 0x1; }

    // Same future type driven via the free fn `fetch__Fut__poll` (the pre-existing form) — must agree.
    g_clock = 0;
    var gf: fetch__Fut = fetch(1, 99);
    let q0: bool = fetch__Fut__poll(&gf);    // clock 0: pending
    tick_idle();                              // clock 1
    let q1: bool = fetch__Fut__poll(&gf);    // ready -> true
    if !q0 && q1 && fetch__Fut_take_result(&gf) == 99 { acc = acc ^ 0x2; }

    if acc != 0x3 { return 0; }
    return 1;
}
