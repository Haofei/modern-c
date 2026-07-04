// EXPECT: E_DUPLICATE_LOCAL
// A `for x in xs` binds its element `x` into the loop-body scope (sema's checkForBody/addForBinding).
// If `x` is already live (here an outer `let x`), re-binding it is E_DUPLICATE_LOCAL — exactly what a
// non-async fn reports. Without binding the for-element, the async dup-check would skip the collision
// and the fn would later hit a DIFFERENT (wrong) diagnostic instead. src/async_lower.zig dupCheckStmt
// `.loop` case binds the `.@"for"` element into the pushed child frame to match sema.
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

async fn dup_for(d: u64, xs: [4]i32) -> i32 {
    let x: i32 = 0;
    var acc: i32 = x;
    for x in xs {                // `x` already live -> E_DUPLICATE_LOCAL at the for-element
        acc = acc + x;
    }
    let r: i32 = await mk_val(d, 7);
    return r + acc;
}
