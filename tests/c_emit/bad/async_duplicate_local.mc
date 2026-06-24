// EXPECT: E_DUPLICATE_LOCAL
// Two `let`/`var` of the SAME name in the SAME lexical scope is illegal in MC (sema's
// addLocalBinding raises E_DUPLICATE_LOCAL). The async-lowering alpha-renamer runs PRE-sema and
// would otherwise rename the two `acc` apart, silently accepting source that a non-async fn rejects.
// src/async_lower.zig validateNoDuplicateLocals closes that hole: an async fn must reject EXACTLY the
// locally-invalid programs a non-async fn does, with the SAME diagnostic. Legitimate shadowing across
// disjoint scopes stays accepted (see tests/c_emit/fuzz_async_capture_shadow.mc).
import "std/task.mc";

global g_clock: u64 = 0;
struct ValFut { deadline: u64, val: i32 }
fn mk_val(deadline: u64, val: i32) -> ValFut {
    var f: ValFut = uninit;
    f.deadline = deadline;
    f.val = val;
    return f;
}
impl Future for ValFut {
    fn poll(self: *mut ValFut) -> bool { return g_clock >= self.deadline; }
    fn cancel(self: *mut ValFut) -> void { self.val = 0; }
}
fn ValFut_take_result(self: *mut ValFut) -> i32 { return self.val; }
fn ValFut_cancel(self: *mut ValFut) -> void { self.val = 0; }

async fn dup(d: u64) -> i32 {
    var acc: i32 = 0;
    var acc: i32 = 1;            // SAME scope as the first `acc` -> E_DUPLICATE_LOCAL
    let r: i32 = await mk_val(d, 7);
    return r + acc;
}
