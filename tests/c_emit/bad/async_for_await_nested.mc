// EXPECT: E_ASYNC_GENERAL_UNSUPPORTED
// E3c generalized the async-fn lowering to a structured CFG over `let x = await e;`, bool `if`/`else`,
// and `while` loops — arbitrarily nested and sequenced. An `await` inside a `for` loop is still beyond
// it: a `for` has its own iterator/back-edge desugaring the per-suspend-point state numbering does not
// model, so it must be REJECTED (with a clear code), not silently mislowered. (Here the `for` is nested
// inside an await-bearing `while`, which routes the fn to the general path; the general lowerer then
// rejects the await-bearing `for`.)
import "std/task.mc";
struct ValFut { deadline: u64, val: i32 }
fn mk_val(deadline: u64, val: i32) -> ValFut { return .{ .deadline = deadline, .val = val }; }
impl Future for ValFut { fn poll(self: *mut ValFut) -> bool { return g_clock >= self.deadline; } fn cancel(self: *mut ValFut) -> void { self.val = 0; } }
fn ValFut_take_result(self: *mut ValFut) -> i32 { return self.val; }
fn ValFut_cancel(self: *mut ValFut) -> void { self.val = 0; }
global g_clock: u64 = 0;
async fn bad(xs: [3]i32, d: u64) -> i32 {
    var acc: i32 = 0;
    var i: i32 = 0;
    while i < 3 {
        let a: i32 = await mk_val(d, i);
        for x in xs { let b: i32 = await mk_val(d, x); acc = acc + b; }   // await inside a `for` — unsupported
        i = i + 1;
    }
    return acc;
}
