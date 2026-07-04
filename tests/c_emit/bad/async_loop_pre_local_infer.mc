// EXPECT: E_ASYNC_LOOP_UNSUPPORTED
// A pre-loop local captured across an await-bearing while loop needs an explicit type in the loop
// fast path; inferred captured fields are deliberately rejected before codegen.
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

async fn bad(limit: i32, d: u64) -> i32 {
    var acc = 0;
    var i: i32 = 0;
    while i < limit {
        let a: i32 = await mk_val(d, i);
        acc = acc + a;
        i = i + 1;
    }
    return acc;
}
