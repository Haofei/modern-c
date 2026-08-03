// EXPECT: E_ASYNC_BORROW_ACROSS_AWAIT
// Same pinning hazard as async_borrow_pinning.mc, but using explicit scoped borrow syntax.
// More generally, Scoped Affine Ownership v0 does not let explicit `borrow` / `borrow mut` be
// captured by an awaited future. End the borrow before await, move owned state into the future, or
// rebuild the view after the await.
import "std/task.mc";
global g_clock: u64 = 0;
struct AtFut { deadline: u64, src: *i32 }
fn mk_at(src: *i32, deadline: u64) -> AtFut { var f: AtFut = uninit; f.src = src; f.deadline = deadline; return f; }
impl Future for AtFut {
    fn poll(self: *mut AtFut) -> bool { return g_clock >= self.deadline; }
    fn cancel(self: *mut AtFut) -> void { }
}
fn AtFut_take_result(self: *mut AtFut) -> i32 { return *self.src; }
fn AtFut_cancel(self: *mut AtFut) -> void { }
async fn pinned(base: i32, d: u64) -> i32 {
    let r: i32 = await mk_at(borrow base, d);
    return r;
}
async fn pinned_mut(base: i32, d: u64) -> i32 {
    var local: i32 = base;
    let r: i32 = await mk_at(borrow mut local, d);
    return r;
}
