// EXPECT: E_ASYNC_BORROW_ACROSS_AWAIT
// E4 deliberately does NOT support self-referential / pinned futures. Here the FIRST await's argument
// takes the address of a captured PARAMETER: `await mk_at(&base, ...)` where `base` is a param (params
// are always captured fields). The transform builds child0 BY VALUE in the constructor as
// `self.__c0 = mk_at(&self.base, ...)`, so the child captures a
// pointer INTO the constructor's transient `self`. After the by-value `return self`, the caller's
// future lives at a new address and that pointer dangles — a self-referential future that would need
// pinning (the pointer must be patched on every move), unsupported in async v0. Unlike a pre-loop
// `let p = &acc;` (E4 relocates that into the poll loop-head at the stable `*mut self`), a first-await
// arg is NOT relocatable: the child must be built before the first suspend and its captured pointer
// is part of the moved-out value. So this stays REJECTED (checkNoSelfBorrow sees `&self.base` in the
// constructor). fail-closed.
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
    let r: i32 = await mk_at(&base, d);   // &param -> self.__c0 = mk_at(&self.base, d) in ctor
    return r;
}
