// EXPECT: E_DUPLICATE_LOCAL
// A switch arm's `.tag_bind` payload ALWAYS binds (the subject is a union/Result), so a payload name
// that shadows a STILL-LIVE same-named outer binding is E_DUPLICATE_LOCAL under MC's no-shadow rule
// — exactly as a non-async fn reports. The async pre-sema transforms no longer model switch-pattern
// binding (sema is authoritative) AND the alpha-renamer no longer renames switch-arm pattern names,
// so this invalid shadowing is NOT masked: the program reaches sema, which rejects it (the renamer
// change must not re-accept what non-async rejects). The disjoint-scope reuse stays VALID — see the
// positive fixtures fuzz_async_shadow_pattern.mc / fuzz_async_switch_pattern_sema.mc.
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

async fn shadow(d: u64, r: Result<i32, i32>) -> i32 {
    let q: i32 = await mk_val(d, 7);
    let x: i32 = 1;                 // still live below
    switch r {
        ok(x) => { return x + q; },  // payload `x` shadows the live outer `x` -> E_DUPLICATE_LOCAL
        err(e) => { return e + x + q; },
    }
}
