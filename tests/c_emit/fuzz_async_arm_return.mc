// ROOT-CAUSE coverage (src/async_lower.zig, branch fast path): an await-bearing if/else where ONE
// arm has ZERO awaits and ends in `return expr;`. The dispatch lowered such a zero-await arm's
// straight-line tail with `rewriteStmtParamRefs`, which does NOT turn a `return expr;` into the
// terminal DONE transition (`self.result = expr; self.state = DONE; return true;`) — it left a bare
// `return <expr>;` (an i32/u64/...) emitted INTO the bool-returning `poll`, which the type checker
// rejected as E_RETURN_TYPE_MISMATCH (a generated-decl error at 0:0 on VALID source). This also
// surfaced for `var x = param;` (a captured pre-branch local) followed by an await-bearing branch
// whose untaken arm just `return x;` — same zero-await-arm-return shape. FIX: route a zero-await
// arm's tail through `rewriteRegionBlock` (the same rewriter the await-bearing arms + tail use), so a
// `return` becomes the DONE transition; the trailing fall-through edge stays correct for a
// non-returning arm. Pre-fix these fns do NOT compile (E_RETURN_TYPE_MISMATCH), so this whole fixture
// fails to build before the fix.
//
// VALUE-SENSITIVE: the zero-await arm returns a value DISTINCT from the await arm's value, and the
// `var x = p;` carrier yields a value DISTINCT from a wrong (e.g. zeroed-field / mis-read) lowering,
// so a regression that mis-lowers the return would change the asserted result, not merely fail to
// compile.

import "std/task.mc";

global g_clock: u64 = 0;
fn tick_idle() -> void { g_clock = g_clock + 1; }

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

// ---- (1) await THEN arm, zero-await ELSE arm that `return`s the PARAM. The else arm must lower to
// `self.result = self.p; self.state = DONE; return true;`, NOT a bare `return self->p;` (E_RTM).
//   r1(p=100, true):  await 7  -> 7 + 100 = 107.
//   r1(p=100, false): else arm returns p = 100.
async fn r1(p: i32, cond: bool) -> i32 {
    if cond {
        let r: i32 = await mk_val(0, 7);
        return r + p;
    } else {
        return p;
    }
}

// ---- (2) MIRROR: zero-await THEN arm that `return`s; await ELSE arm. Exercises the then-arm dispatch
// path (the other half of the fix).
//   r2(p=50, true):  then arm returns p = 50.
//   r2(p=50, false): await 9 -> 9 + 50 = 59.
async fn r2(p: i32, cond: bool) -> i32 {
    if cond {
        return p;
    } else {
        let r: i32 = await mk_val(0, 9);
        return r + p;
    }
}

// ---- (3) `var x = param;` (a captured pre-branch local) live across an await-bearing branch whose
// ELSE arm has zero awaits and `return`s the local. The captured-field replay (`self.x = self.p;`)
// plus the zero-await else DONE-transition both must be correct.
//   v1(p=40, true):  x=40; await 7 -> 7 + 40 = 47.
//   v1(p=40, false): x=40; else returns x = 40.
async fn v1(p: i32, cond: bool) -> i32 {
    var x: i32 = p;
    if cond {
        let r: i32 = await mk_val(0, 7);
        return r + x;
    } else {
        return x;
    }
}

// ---- (4) zero-await else arm whose `return` reads a PRE-BRANCH constant-init captured local (no
// param flow), distinguishing the local's stored value from a mis-zeroed field.
//   v2(true):  x=13; await 5 -> 5 + 13 = 18.
//   v2(false): else returns x = 13 (NOT 0 — would mean the field replay was dropped).
async fn v2(cond: bool) -> i32 {
    var x: i32 = 13;
    if cond {
        let r: i32 = await mk_val(0, 5);
        return r + x;
    } else {
        return x;
    }
}

export fn async_arm_return_run() -> u32 {
    var passmask: u32 = 0;
    g_clock = 0;

    var a1: r1__Fut = r1(100, true);
    run_to_completion(&a1, tick_idle);
    if r1__Fut_take_result(&a1) == 107 { passmask = passmask ^ 0x01; }

    var a1e: r1__Fut = r1(100, false);
    run_to_completion(&a1e, tick_idle);
    if r1__Fut_take_result(&a1e) == 100 { passmask = passmask ^ 0x02; }

    var a2: r2__Fut = r2(50, true);
    run_to_completion(&a2, tick_idle);
    if r2__Fut_take_result(&a2) == 50 { passmask = passmask ^ 0x04; }

    var a2e: r2__Fut = r2(50, false);
    run_to_completion(&a2e, tick_idle);
    if r2__Fut_take_result(&a2e) == 59 { passmask = passmask ^ 0x08; }

    var a3: v1__Fut = v1(40, true);
    run_to_completion(&a3, tick_idle);
    if v1__Fut_take_result(&a3) == 47 { passmask = passmask ^ 0x10; }

    var a3e: v1__Fut = v1(40, false);
    run_to_completion(&a3e, tick_idle);
    if v1__Fut_take_result(&a3e) == 40 { passmask = passmask ^ 0x20; }

    var a4: v2__Fut = v2(true);
    run_to_completion(&a4, tick_idle);
    if v2__Fut_take_result(&a4) == 18 { passmask = passmask ^ 0x40; }

    var a4e: v2__Fut = v2(false);
    run_to_completion(&a4e, tick_idle);
    if v2__Fut_take_result(&a4e) == 13 { passmask = passmask ^ 0x80; }

    if passmask != 0xFF { return 0; }
    return 1;
}
