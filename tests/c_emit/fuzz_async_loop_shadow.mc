// Recurring bug class (src/async_lower.zig): identifier-rewrite sites that DON'T honor lexical
// shadowing of a captured name, in the NON-renamed FAST paths (the general path is immune via its
// alpha-rename). VALUE-SENSITIVE — every assertion would FAIL on the pre-fix tree, where the wrong
// binding (the captured self.* field) was read silently.
//
//   #1 (loop-body switch pattern shadow): a `switch` arm pattern (`number(x)`) inside an await-bearing
//      `while` body introduces a REAL arm-local that SHADOWS a captured outer name. The loop-body
//      rewriter (rewriteLoopBodyStmtIn) previously applied NO shadow-remove (unlike the region/general
//      sites), so the in-arm `x` was rewritten to `self->x` (the awaited binding) instead of the arm
//      PAYLOAD — a silent miscompile.
//   #2 (loop-body let/var shadow): a `let p` inside a loop body that SHADOWS the param `p` was read as
//      `self->p` (the param) instead of the region-local, because the fast-path block rewriters never
//      removed a shadowing local from the capture set.
//   #3 (post-loop tail let/var shadow): same shadow bug in the straight-line tail after the loop.
//   #4 (#2 carrier no-clobber): `await ctx.fut` over a PARAM `ctx: Ctx` must still resolve even when an
//      inner block declares `let ctx: Other` — the flat carrier-type map previously let the inner
//      typed local CLOBBER the param entry function-wide -> E_ASYNC_AWAIT_UNRESOLVED (fail-closed).

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

union Token { number: i32, eof }

// ---- #1 loop-body switch-pattern shadow. The `number(x)` arm in the loop body must read the PAYLOAD
// `x`, NOT the captured awaited binding `x` (= awaited 42). Payload is 7 each iteration.
//   g1(n=3, t=number(7)): each iter awaits 42 into x, then adds PAYLOAD 7 -> acc = 3*7 = 21.
//   Pre-fix it added self->x (awaited 42) -> 3*42 = 126.
async fn g1(d: u64, t: Token, n: i32) -> i32 {
    var acc: i32 = 0;
    var i: i32 = 0;
    while i < n {
        let x: i32 = await mk_val(d, 42);
        switch t {
            number(x) => { acc = acc + x; },
            .eof => { acc = acc + 1; },
        }
        i = i + 1;
    }
    return acc;
}

// ---- #2 loop-body let/var shadow of a PARAM. `let p = r + 1` shadows param `p` for the rest of the
// body; `acc = acc + p` must read the LOCAL (r+1), not the param.
//   g2(p=1000, n=2): each iter awaits r=5, p_local = 6, acc += 6 -> acc = 12.
//   Pre-fix read self->p (param 1000) -> 2000.
async fn g2(d: u64, p: i32, n: i32) -> i32 {
    var acc: i32 = 0;
    var i: i32 = 0;
    while i < n {
        let r: i32 = await mk_val(d, 5);
        let p: i32 = r + 1;
        acc = acc + p;
        i = i + 1;
    }
    return acc;
}

// ---- #3 post-loop TAIL let/var shadow of a param. After the loop, `let base = acc * 2` shadows param
// `base`; the return must read the local, not the param.
//   g3(base=1000, n=2): loop sums awaited 5 twice -> acc=10; tail base_local = acc*2 = 20; return 20.
//   Pre-fix returned self->base (param 1000) added wrongly.
async fn g3(d: u64, base: i32, n: i32) -> i32 {
    var acc: i32 = 0;
    var i: i32 = 0;
    while i < n {
        let r: i32 = await mk_val(d, 5);
        acc = acc + r;
        i = i + 1;
    }
    let base: i32 = acc * 2;
    return base;
}

// ---- #4 carrier no-clobber: PARAM `ctx: Ctx` awaited via `ctx.fut`; an inner block declares
// `let ctx: Other`. The param await must resolve AND the inner ctx.g must read the local Other.
struct Ctx { fut: ValFut }
struct Other { g: i32 }
fn mk_ctx(d: u64, val: i32) -> Ctx {
    var c: Ctx = uninit;
    c.fut = mk_val(d, val);
    return c;
}
//   g4(cond=true): r = await ctx.fut = 99; inner ctx_local.g = 5; return r + 5 = 104.
async fn g4(ctx: Ctx, cond: bool) -> i32 {
    let r: i32 = await ctx.fut;
    if cond { let ctx: Other = .{ .g = 5 }; return r + ctx.g; }
    return r;
}

export fn async_loop_shadow_run() -> u32 {
    var acc: u32 = 0;
    g_clock = 0;

    // #1 loop-body switch pattern: payload 7 each iter -> 3*7 = 21 (NOT awaited 42 -> 126).
    var a1: g1__Fut = g1(0, number(7), 3);
    run_to_completion(&a1, tick_idle);
    if g1__Fut_take_result(&a1) == 21 { acc = acc ^ 0x01; }

    // #1 .eof arm (no binding): +1 each iter -> 3.
    var a1e: g1__Fut = g1(0, eof(), 3);
    run_to_completion(&a1e, tick_idle);
    if g1__Fut_take_result(&a1e) == 3 { acc = acc ^ 0x02; }

    // #2 loop-body let shadow of param: local p=6 each iter -> 2*6 = 12 (NOT param 1000).
    var a2: g2__Fut = g2(0, 1000, 2);
    run_to_completion(&a2, tick_idle);
    if g2__Fut_take_result(&a2) == 12 { acc = acc ^ 0x04; }

    // #3 tail let shadow of param: acc=10, base_local = 20 (NOT param 1000).
    var a3: g3__Fut = g3(0, 1000, 2);
    run_to_completion(&a3, tick_idle);
    if g3__Fut_take_result(&a3) == 20 { acc = acc ^ 0x08; }

    // #4 carrier no-clobber: param await 99 + inner Other.g 5 = 104.
    var a4: g4__Fut = g4(mk_ctx(0, 99), true);
    run_to_completion(&a4, tick_idle);
    if g4__Fut_take_result(&a4) == 104 { acc = acc ^ 0x10; }

    if acc != 0x1F { return 0; }
    return 1;
}
