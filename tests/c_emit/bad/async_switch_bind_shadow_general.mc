// EXPECT: E_DUPLICATE_LOCAL
// GENERAL-path companion to bad/async_switch_bind_shadow.mc. Here the body takes the alpha-renaming
// general path (TWO separate await-bearing `if` blocks), which renames the outer `var x` to a unique
// name BEFORE sema — so sema can no longer see the source collision when the `ok(x)` payload (a
// `.tag_bind`, which ALWAYS binds, type-INDEPENDENT) shadows the still-live outer `x`. Pre-fix this
// was a DOUBLE bug: the E_DUPLICATE_LOCAL non-async reports was MASKED, and the arm body's `return x`
// alpha-renamed to the OUTER carrier (`self->x__a0`) instead of the payload — a SILENT MISCOMPILE
// (the payload local was emitted dead/MC_UNUSED). FIX: `validateNoDuplicateLocals` dup-checks a
// single-pattern `.tag_bind` payload PRE-rename, so the collision is rejected before the renamer can
// mis-resolve the payload read. (Bare `.bind` stays type-dependent / deferred to sema; multi-pattern
// arms stay E_SWITCH_MULTI_BINDING_ARM — see bad/async_switch_multi_binding.mc.)
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

async fn shadow_general(d: u64, r: Result<i32, i32>, cond: bool) -> i32 {
    var x: i32 = 1;
    if cond { let q: i32 = await mk_val(d, 7); x = x + q; }
    if cond { let w: i32 = await mk_val(d, 0); }
    switch r {
        ok(x) => { return x; },        // payload `x` shadows the still-live outer `x` -> E_DUPLICATE_LOCAL
        err(e) => { return e + x; },
    }
}
