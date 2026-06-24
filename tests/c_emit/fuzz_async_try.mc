// Phase D richer syntax: `try await` — `let x = (await e)?;` where the awaited value is a Result.
// The `?` propagates the `err` up the async fn (which itself returns a Result), completing the
// future early with that error; on `ok` it binds the unwrapped value and continues. Driven through
// the Phase-A executor; both backends must agree.

import "std/task.mc";

global g_clock: u64 = 0;
fn tick_idle() -> void { g_clock = g_clock + 1; }

// A leaf future yielding a Result<i32,i32>: err(v) if v < 0, else ok(v). Uniform leaf ABI.
struct RFut { deadline: u64, v: i32 }
fn mk(deadline: u64, v: i32) -> RFut { var f: RFut = uninit; f.deadline = deadline; f.v = v; return f; }
impl Future for RFut { fn poll(self: *mut RFut) -> bool { return g_clock >= self.deadline; } fn cancel(self: *mut RFut) -> void { self.v = 0; } }
fn RFut_take_result(self: *mut RFut) -> Result<i32, i32> {
    if self.v < 0 { return err(self.v); }
    return ok(self.v);
}
fn RFut_cancel(self: *mut RFut) -> void { self.v = 0; }

// Two try-awaits in sequence: if the first errs, the second never runs and the error propagates.
async fn chain(d: u64, v1: i32, v2: i32) -> Result<i32, i32> {
    let a: i32 = (await mk(d, v1))?;
    let b: i32 = (await mk(d, v2))?;
    return ok(a + b);
}

export fn async_try_run() -> u32 {
    var acc: u32 = 0;

    // ok path: v1=20, v2=22 -> ok(42)
    g_clock = 0;
    var f: chain__Fut = chain(1, 20, 22);
    run_to_completion(&f, tick_idle);
    switch chain__Fut_take_result(&f) {
        ok(x) => { if x == 42 { acc = acc ^ 0x1; } }
        err(e) => { }
    }

    // err on the FIRST await: v1=-5 -> err(-5) propagated; second await never runs
    g_clock = 0;
    var f2: chain__Fut = chain(1, -5, 22);
    run_to_completion(&f2, tick_idle);
    switch chain__Fut_take_result(&f2) {
        ok(x) => { }
        err(e) => { if e == -5 { acc = acc ^ 0x2; } }
    }

    // err on the SECOND await: v1=7 (ok), v2=-9 -> err(-9) propagated
    g_clock = 0;
    var f3: chain__Fut = chain(1, 7, -9);
    run_to_completion(&f3, tick_idle);
    switch chain__Fut_take_result(&f3) {
        ok(x) => { }
        err(e) => { if e == -9 { acc = acc ^ 0x4; } }
    }

    if acc != 0x7 { return 0; }
    return 1;
}
