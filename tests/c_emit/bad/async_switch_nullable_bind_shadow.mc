// EXPECT: E_DUPLICATE_LOCAL
// A bare switch `.bind` (`x =>`) is TYPE-DEPENDENT: sema binds it ONLY for a NULLABLE subject (the
// unwrap) — a non-nullable subject's bare `.bind` is a no-op catch-all that binds NOTHING. Here the
// PARAM subject `maybe: ?*mut i32` is nullable, so the `.bind` binds the unwrap, and the bound name `x`
// shadows the still-live outer `let x`. On the GENERAL path (two await-bearing ifs) the outer `x` is
// alpha-renamed to a `self.*` field BEFORE sema, so sema can no longer see the source collision: pre-fix
// this MASKED the E_DUPLICATE_LOCAL non-async reports (and read the OUTER carrier instead of the unwrap).
//
// ROOT FIX (shared by all bad/async_switch_*_nullable*_shadow.mc): the async lowering only DETECTS the
// collision (the bare `.bind` name shadows a lifted outer local — type-INDEPENDENT) and sets
// SwitchArm.dup_local_if_binds; sema, which has the RESOLVED subject type, reports E_DUPLICATE_LOCAL iff
// it actually binds the arm (nullable subject). No syntactic nullability re-derivation — so a nullable
// param/typed-local/qualified/call/member subject all reject identically, while a non-nullable subject's
// catch-all is accepted. Sibling fixtures cover the typed-LOCAL, QUALIFIED (`const ?T`), and CALL/MEMBER
// subject shapes.
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

async fn nullable_shadow_general(d: u64, maybe: ?*mut i32, p: *mut i32, cond: bool) -> usize {
    let x: *mut i32 = p;                         // still live below
    if cond { let q: i32 = await mk_val(d, 7); if q == 999 { return 0; } }
    if cond { let w: i32 = await mk_val(d, 0); if w == 999 { return 0; } }
    switch maybe {
        x => { return x as usize; },             // nullable-param unwrap `x` shadows live outer `x` -> E_DUPLICATE_LOCAL
        _ => { return x as usize; },
    }
}
