// EXPECT: E_ASYNC_AWAIT_UNRESOLVED
// Awaiting through a dynamic Future pointer is intentionally not resolvable by the async lowering's
// pre-sema syntactic future-type map. It must fail closed with the dedicated diagnostic.
import "std/task.mc";

struct ValFut { deadline: u64, val: i32 }
fn mk_val(deadline: u64, val: i32) -> ValFut {
    return .{ .deadline = deadline, .val = val };
}
impl Future for ValFut {
    fn poll(self: *mut ValFut) -> bool { return self.deadline == 0; }
    fn cancel(self: *mut ValFut) -> void { self.val = 0; }
}
fn ValFut_take_result(self: *mut ValFut) -> i32 { return self.val; }
fn ValFut_cancel(self: *mut ValFut) -> void { self.val = 0; }

async fn bad(f: *mut dyn Future) -> i32 {
    let r: i32 = await f;
    return r;
}
