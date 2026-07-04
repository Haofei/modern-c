// EXPECT: E_ASYNC_BRANCH_UNSUPPORTED
// A pre-branch local captured across an await-bearing if/else needs an explicit type in the branch
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

async fn bad(sel: bool, d: u64) -> i32 {
    var acc = 0;
    if sel {
        let a: i32 = await mk_val(d, 1);
        acc = acc + a;
    } else {
        let b: i32 = await mk_val(d, 2);
        acc = acc + b;
    }
    return acc;
}
