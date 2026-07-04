// EXPECT: E_DUPLICATE_LOCAL
// A switch arm's `.tag_bind` payload ALWAYS binds (the subject is a union/Result) — INDEPENDENT of the
// subject type — so a payload name that shadows a STILL-LIVE same-named outer binding is
// E_DUPLICATE_LOCAL under MC's no-shadow rule, exactly as a non-async fn reports. This is the FAST-path
// shape (one straight-line await then the switch); its general-path companion (where the outer is
// alpha-renamed away pre-sema) is bad/async_switch_bind_shadow_general.mc. `validateNoDuplicateLocals`
// dup-checks a single-pattern `.tag_bind` payload PRE-rename, so this invalid shadowing is rejected on
// BOTH paths and is never masked (the renamer must not re-accept what non-async rejects). The
// disjoint-scope reuse stays VALID — see the positive fixtures fuzz_async_shadow_pattern.mc /
// fuzz_async_switch_pattern_sema.mc.
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

async fn shadow(d: u64, r: Result<i32, i32>) -> i32 {
    let q: i32 = await mk_val(d, 7);
    let x: i32 = 1;                 // still live below
    switch r {
        ok(x) => { return x + q; },  // payload `x` shadows the live outer `x` -> E_DUPLICATE_LOCAL
        err(e) => { return e + x + q; },
    }
}
