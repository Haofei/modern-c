// EXPECT: E_DUPLICATE_PARAMETER
// Two params with the same name is E_DUPLICATE_PARAMETER in sema (checkFn), NOT E_DUPLICATE_LOCAL.
// src/async_lower.zig validateNoDuplicateLocals detects param-vs-param collisions separately, before
// seeding the local scope, so an async fn reports the SAME code+message as a non-async fn. (A body
// local later shadowing a unique param still reports E_DUPLICATE_LOCAL via the normal scope check.)
import "std/task.mc";

global g_clock: u64 = 0;
struct ValFut { deadline: u64, val: i32 }
fn mk_val(deadline: u64, val: i32) -> ValFut {
    return .{ .deadline = deadline, .val = val };
}
impl Future for ValFut {
    fn poll(self: *mut ValFut) -> bool { return g_clock >= self.deadline; }
    fn cancel(self: *mut ValFut) -> void { self.val = 0; }
}
fn ValFut_take_result(self: *mut ValFut) -> i32 { return self.val; }
fn ValFut_cancel(self: *mut ValFut) -> void { self.val = 0; }

async fn dup_param(x: i32, x: bool) -> i32 {   // two params named `x` -> E_DUPLICATE_PARAMETER
    let r: i32 = await mk_val(0, 7);
    return r + x;
}
