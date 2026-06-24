// EXPECT: E_DUPLICATE_LOCAL
// A bare switch `.bind` (`x =>`) is TYPE-DEPENDENT: sema binds it ONLY for a NULLABLE subject (the
// unwrap) — a non-nullable subject's bare `.bind` is a no-op catch-all that binds NOTHING. So unlike
// `.tag_bind` (always binds — see bad/async_switch_bind_shadow*.mc), it cannot be unconditionally
// dup-checked pre-sema without false-rejecting the valid non-nullable `switch n { x => x; _ => }` form.
//
// BUT when the subject is a bare ref to a NULLABLE-typed PARAM, nullability is known SYNTACTICALLY (the
// async pass resolves types syntactically, no sema), and a param is never shadowed by a local (that is
// itself E_DUPLICATE_LOCAL), so the subject ident maps unambiguously to that nullable param — the
// `.bind` binds the unwrap exactly as sema does. Here the bound name `x` shadows the still-live outer
// `let x`. On the GENERAL path (two await-bearing ifs) the outer `x` is alpha-renamed to a `self.*`
// field BEFORE sema, so sema can no longer see the source collision: pre-fix this MASKED the
// E_DUPLICATE_LOCAL non-async reports (and, were it run, read the OUTER carrier instead of the unwrap).
// `validateNoDuplicateLocals` now dup-checks a single-pattern `.bind` over a nullable PARAM subject
// PRE-rename, restoring parity. (A nullable LOCAL/complex subject stays a bounded, type-info-only
// residual — not closable pre-sema without resolving its type.)
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
