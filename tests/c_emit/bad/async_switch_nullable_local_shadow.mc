// EXPECT: E_DUPLICATE_LOCAL
// Companion to bad/async_switch_nullable_bind_shadow.mc (which uses a nullable PARAM subject): here the
// switch subject is a nullable-typed LOCAL (`let maybe: ?*mut i32`). The bare `.bind` `x` binds the
// unwrap (nullable subject) and shadows the still-live outer `let x`. On the GENERAL path (two
// await-bearing ifs) the outer `x` is alpha-renamed to a `self.*` field before sema, so without the
// fix this MASKED the E_DUPLICATE_LOCAL non-async reports AND emitted a wrong-code arm (both arms
// returned the renamed outer `self->x__a1` while the payload local sat MC_UNUSED). ROOT FIX (see
// bad/async_switch_nullable_bind_shadow.mc for the full note): the lowering DETECTS the collision and
// sets SwitchArm.dup_local_if_binds; sema reports E_DUPLICATE_LOCAL iff it binds the arm (resolved
// nullable subject) — so param/local/qualified/call/member subjects all reject by the same mechanism.
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

async fn nullable_local_shadow_general(d: u64, source: ?*mut i32, p: *mut i32, cond: bool) -> usize {
    let maybe: ?*mut i32 = source;
    let x: *mut i32 = p;                         // still live below
    if cond { let q: i32 = await mk_val(d, 7); if q == 999 { return 0; } }
    if cond { let w: i32 = await mk_val(d, 0); if w == 999 { return 0; } }
    switch maybe {
        x => { return x as usize; },             // nullable-local unwrap `x` shadows live outer `x` -> E_DUPLICATE_LOCAL
        _ => { return x as usize; },
    }
}
