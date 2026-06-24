// ROOT-CAUSE coverage (src/async_lower.zig): the fast paths build the future-struct's CAPTURED
// fields BY ORIGINAL binding name from three sources — params, pre-REGION (pre-branch/pre-loop)
// top-level locals, and awaited bindings. When a pre-region top-level LOCAL (or an awaited binding)
// SHADOWS a param of the same name, the fast path emitted TWO struct fields of that name
// (E_DUPLICATE_STRUCT_FIELD) and resolved `await x.fut` through the FIRST-writer carrier (the param)
// instead of the local (E_RETURN_TYPE_MISMATCH) — both broken-generated-struct errors on VALID
// shadowing source. FIX: `fastPathCaptureCollision` routes any such fn to the alpha-renaming general
// path, where every local gets a globally-unique name so neither a duplicate field nor a carrier
// mis-resolution is possible.
//
// VALUE-SENSITIVE: in every case the LOCAL carrier yields a value DISTINCT from what the param carrier
// would yield, so a pre-fix carrier mis-resolution (reading the PARAM's future) would change the
// result. On the pre-fix tree these fns don't even COMPILE (duplicate field + return-type mismatch),
// so this whole fixture fails to build before the fix.

import "std/task.mc";

global g_clock: u64 = 0;
fn tick_idle() -> void { g_clock = g_clock + 1; }

// leaf: ready at `deadline`, yielding `val`; uniform poll/take_result/cancel ABI.
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

// Two DISTINCT carrier struct types holding a ValFut, so a local-shadows-param of the same name has a
// genuinely different carrier type (the duplicate-field + carrier-mismatch trigger).
struct Ctx   { fut: ValFut }            // the PARAM carrier
struct Other { fut: ValFut, g: i32 }    // the LOCAL carrier (extra field — distinct type)

fn mk_ctx(d: u64, v: i32) -> Ctx { var c: Ctx = uninit; c.fut = mk_val(d, v); return c; }
fn mk_other(d: u64, v: i32, g: i32) -> Other {
    var o: Other = uninit; o.fut = mk_val(d, v); o.g = g; return o;
}

// ---- (1) PRE-BRANCH local shadows a PARAM, await over the LOCAL carrier in an arm. The param `ctx`
// (Ctx, fut=param value) is shadowed at the top level by `let ctx: Other` (fut=777). The arm awaits
// `ctx.fut` — which MUST be the LOCAL's future (777), plus the local's `g` (9). The param value is
// chosen as 100 so a pre-fix carrier mis-resolution (param's fut) would change the sum.
//   c1(ctx=mk_ctx(.,100), cond=true): local Other fut=777, g=9 -> await 777, return 777 + 9 = 786.
//   Mis-resolving to the PARAM would have awaited 100 -> 109.
async fn c1(ctx: Ctx, cond: bool) -> i32 {
    let ctx: Other = mk_other(0, 777, 9);
    if cond {
        let r: i32 = await ctx.fut;
        return r + ctx.g;
    } else {
        return 0;
    }
}

// ---- (2) PRE-LOOP local shadows a PARAM, await over the LOCAL carrier in the loop body. Same shadow
// shape but the await-bearing construct is a `while`. The param `ctx` (Ctx, fut=200) is shadowed by a
// pre-loop `let ctx: Other` (fut=11, g=3). Each iteration awaits the LOCAL's fut (11) and adds g (3).
//   c2(ctx=mk_ctx(.,200), n=2): per iter 11 + 3 = 14, two iters -> 28.
//   Mis-resolving to the PARAM would have awaited 200 per iter -> 406.
async fn c2(ctx: Ctx, n: i32) -> i32 {
    let ctx: Other = mk_other(0, 11, 3);
    var acc: i32 = 0;
    var i: i32 = 0;
    while i < n {
        let r: i32 = await ctx.fut;
        acc = acc + r + ctx.g;
        i = i + 1;
    }
    return acc;
}

// ---- (3) AWAITED-binding name collides with a PARAM. The awaited binding `let p = await ...` shadows
// param `p: i32`. Pre-fix both became a struct field named `p` -> E_DUPLICATE_STRUCT_FIELD; the await
// binding must read the AWAITED value (55), then the tail uses it, NOT the param (1000).
//   c3(p=1000, cond=true): p_local = await 55; return p_local + 1 = 56.
//   A pre-fix duplicate/clobber would surface the param 1000 -> 1001.
async fn c3(p: i32, cond: bool) -> i32 {
    if cond {
        let p: i32 = await mk_val(0, 55);
        return p + 1;
    } else {
        return p;   // the else arm legitimately uses the PARAM p
    }
}

// ---- (4) LOCAL-vs-LOCAL: two pre-branch top-level locals named `acc` (the second shadows the first),
// both captured. Pre-fix two fields named `acc` -> E_DUPLICATE_STRUCT_FIELD. The second `acc` (=5)
// must win for the await-arm sum.
//   c4(d, cond=true): first acc=1 (shadowed), second acc=5; arm awaits 40 -> return 40 + 5 = 45.
async fn c4(d: u64, cond: bool) -> i32 {
    let acc: i32 = 1;
    let acc: i32 = 5;
    if cond {
        let r: i32 = await mk_val(d, 40);
        return r + acc;
    } else {
        return acc;
    }
}

export fn async_capture_shadow_run() -> u32 {
    var passmask: u32 = 0;
    g_clock = 0;

    // (1) pre-branch local-shadows-param, await over LOCAL carrier: 777 + 9 = 786.
    var a1: c1__Fut = c1(mk_ctx(0, 100), true);
    run_to_completion(&a1, tick_idle);
    if c1__Fut_take_result(&a1) == 786 { passmask = passmask ^ 0x01; }

    // (1b) else arm taken: 0 (no await; just confirms the shadow fn lowers + both arms work).
    var a1e: c1__Fut = c1(mk_ctx(0, 100), false);
    run_to_completion(&a1e, tick_idle);
    if c1__Fut_take_result(&a1e) == 0 { passmask = passmask ^ 0x02; }

    // (2) pre-loop local-shadows-param, await over LOCAL carrier each iter: 2 * (11 + 3) = 28.
    var a2: c2__Fut = c2(mk_ctx(0, 200), 2);
    run_to_completion(&a2, tick_idle);
    if c2__Fut_take_result(&a2) == 28 { passmask = passmask ^ 0x04; }

    // (2b) zero-iteration loop: acc stays 0.
    var a2z: c2__Fut = c2(mk_ctx(0, 200), 0);
    run_to_completion(&a2z, tick_idle);
    if c2__Fut_take_result(&a2z) == 0 { passmask = passmask ^ 0x08; }

    // (3) awaited-binding shadows param: 55 + 1 = 56.
    var a3: c3__Fut = c3(1000, true);
    run_to_completion(&a3, tick_idle);
    if c3__Fut_take_result(&a3) == 56 { passmask = passmask ^ 0x10; }

    // (3b) else arm reads the genuine PARAM p = 1000.
    var a3e: c3__Fut = c3(1000, false);
    run_to_completion(&a3e, tick_idle);
    if c3__Fut_take_result(&a3e) == 1000 { passmask = passmask ^ 0x20; }

    // (4) local-vs-local: second acc (5) wins: 40 + 5 = 45.
    var a4: c4__Fut = c4(0, true);
    run_to_completion(&a4, tick_idle);
    if c4__Fut_take_result(&a4) == 45 { passmask = passmask ^ 0x40; }

    if passmask != 0x7F { return 0; }
    return 1;
}
