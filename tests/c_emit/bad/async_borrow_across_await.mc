// EXPECT: E_ASYNC_BORROW_ACROSS_AWAIT
// A reference to a captured local (`&buf`) held across an `await`: `buf` and `p` become future
// fields, so the constructor forms `self.p = &self.buf` and returns `self` BY VALUE — the pointer
// dangles after the move (C lucked into 100 via copy-elision; LLVM segfaulted). v0 rejects it
// (self-referential futures need pinning).
import "std/task.mc";
struct ValFut { deadline: u64, val: i32 }
fn mk_val(deadline: u64, val: i32) -> ValFut { return .{ .deadline = deadline, .val = val }; }
impl Future for ValFut { fn poll(self: *mut ValFut) -> bool { return g_clock >= self.deadline; } fn cancel(self: *mut ValFut) -> void { self.val = 0; } }
fn ValFut_take_result(self: *mut ValFut) -> i32 { return self.val; }
fn ValFut_cancel(self: *mut ValFut) -> void { self.val = 0; }
global g_clock: u64 = 0;
async fn bad(d: u64) -> i32 {
    var buf: i32 = 7;
    let p: *mut i32 = &buf;
    var i: i32 = 0;
    while i < 1 { let r: i32 = await mk_val(d, 5); *p = 100; i = i + 1; }
    return buf;
}
