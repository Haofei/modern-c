// EXPECT: E_DUPLICATE_LOCAL
// Companion to bad/async_switch_nullable_{bind,local}_shadow.mc: the nullable switch subject is behind
// a `const` qualifier (`const ?*mut i32`). Sema treats `const ?T` as nullable (`nullableInnerType`
// peels `.qualified`), so the bare `.bind` `x` binds the unwrap and shadows the still-live outer `let
// x`. On the general path the outer `x` alpha-renames to a `self.*` field before sema. ROOT FIX (see
// bad/async_switch_nullable_bind_shadow.mc): the lowering DETECTS the collision (type-independent) and
// sets SwitchArm.dup_local_if_binds; sema reports E_DUPLICATE_LOCAL iff it binds the arm using the
// RESOLVED subject type — so it correctly sees through `const ?T` (and aliases, calls, members) with no
// syntactic qualifier-peeling in the lowering. Covered for a qualified PARAM subject here.
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

async fn qualified_nullable_shadow_general(d: u64, maybe: const ?*mut i32, p: *mut i32, cond: bool) -> usize {
    let x: *mut i32 = p;                         // still live below
    if cond { let q: i32 = await mk_val(d, 7); if q == 999 { return 0; } }
    if cond { let w: i32 = await mk_val(d, 0); if w == 999 { return 0; } }
    switch maybe {
        x => { return x as usize; },             // `const ?*mut i32` unwrap `x` shadows live outer `x` -> E_DUPLICATE_LOCAL
        _ => { return x as usize; },
    }
}
