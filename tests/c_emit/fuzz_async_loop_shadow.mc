// Recurring bug class (src/async_lower.zig): identifier-rewrite sites that DON'T honor lexical
// shadowing of a captured name, and capture-field construction that collides two same-named bindings.
// VALUE-SENSITIVE — every assertion would FAIL on the pre-fix tree, where the wrong binding (the
// captured self.* field, or a clobbered carrier) was read silently.
//
// IMPORTANT — this exercises only LOCALLY-VALID shadowing (the kind ordinary MC accepts): the SAME
// source name reused across DISJOINT lexical scopes. A local re-binding a STILL-LIVE enclosing binding
// of the same name (a `let`/pattern shadowing a live param or a live awaited binding) is NOT valid MC —
// it is E_DUPLICATE_LOCAL, which async fns now reject exactly as non-async fns do (src/async_lower.zig
// validateNoDuplicateLocals; see tests/c_emit/bad/async_duplicate_local.mc). So each `x`/`p`/`base`/
// `ctx` below lives in a scope DISJOINT from the same-named binding it must stay distinct from.
//
//   #1 (loop-body switch pattern, disjoint from a same-named awaited binding): a `switch` arm pattern
//      (`number(x)`) inside an await-bearing `while` body introduces a REAL arm-local; a same-named
//      awaited binding `x` lives in a DISJOINT trailing `if`. The loop-body rewriter must read the arm
//      PAYLOAD inside the arm, and the disjoint `x` its own captured value — two distinct fields.
//   #2 (loop-body let/var reused name): a `let p` inside a loop body and a same-named `let p` in a
//      disjoint trailing `if`; each must read ITS OWN value, not a single shared capture field.
//   #3 (post-loop tail let/var reused name): same name `base` in the loop body and the disjoint tail.
//   #4 (carrier no-clobber): `await ctx.fut` over a PARAM `ctx: Ctx` must still resolve even when a
//      DISJOINT block reuses the name `ctx` for a local `Other` — the flat carrier-type map previously
//      let the inner typed local CLOBBER the param entry function-wide -> E_ASYNC_AWAIT_UNRESOLVED.

import "std/task.mc";

global g_clock: u64 = 0;
fn tick_idle() -> void { g_clock = g_clock + 1; }

// leaf: ready at `deadline`, yielding `val`; uniform poll/take_result/cancel ABI.
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

union Token { number: i32, eof }

// ---- #1 loop-body switch-pattern arm-local `x` (payload) vs a DISJOINT trailing-if binding `x`. Each
// loop iteration awaits a per-iter value `r`, then a `switch` arm `number(x)` reads its PAYLOAD; a
// same-named binding `x` lives in a DISJOINT trailing `if`. The arm must read the PAYLOAD, the trailing
// `if` its OWN awaited `x` (= 50) — two distinct fields.
//   g1(n=3, t=number(7)): each iter awaits r=10 then adds payload 7 -> 3*(7) = 21; trailing awaited 50 -> 71.
//   Pre-fix the arm `x` aliased the trailing capture -> wrong sum.
async fn g1(d: u64, t: Token, n: i32) -> i32 {
    var acc: i32 = 0;
    var i: i32 = 0;
    while i < n {
        let r: i32 = await mk_val(d, 10);
        if r >= 0 {
            switch t {
                number(x) => { acc = acc + x; },
                .eof => { acc = acc + 1; },
            }
        }
        i = i + 1;
    }
    if n > 0 {
        let x: i32 = await mk_val(d, 50);
        acc = acc + x;
    }
    return acc;
}

// ---- #2 loop-body let `p` vs a DISJOINT trailing-if let `p`. Each must read ITS OWN value.
//   g2(n=2): each iter awaits r=5, p_local = 6, acc += 6 -> acc = 12; trailing if: p = 100, acc += 100.
//   Pre-fix a single shared `p` field would clobber across the disjoint scopes.
async fn g2(d: u64, n: i32) -> i32 {
    var acc: i32 = 0;
    var i: i32 = 0;
    while i < n {
        let r: i32 = await mk_val(d, 5);
        let p: i32 = r + 1;
        acc = acc + p;
        i = i + 1;
    }
    if n > 0 {
        let p: i32 = 100;
        acc = acc + p;
    }
    return acc;
}

// ---- #3 loop-body `base` vs post-loop TAIL `base` (disjoint scopes: the loop-body `base` dies at the
// loop's end, the tail `base` is a fresh binding). Each its own value.
//   g3(n=2): loop sums awaited 5 twice using a per-iter base=r+1=6 -> acc += 6 twice = 12; tail
//            base = acc * 2 = 24; return 24.
async fn g3(d: u64, n: i32) -> i32 {
    var acc: i32 = 0;
    var i: i32 = 0;
    while i < n {
        let r: i32 = await mk_val(d, 5);
        let base: i32 = r + 1;
        acc = acc + base;
        i = i + 1;
    }
    let base: i32 = acc * 2;
    return base;
}

// ---- #4 carrier no-clobber: PARAM `ctx: Ctx` awaited via `ctx.fut`; a DISJOINT `if` block reuses the
// name `ctx` for a local `Other`. The param await must resolve AND the inner ctx.g read the local
// Other — the disjoint reuse must not clobber the param carrier-type entry.
struct Ctx { fut: ValFut }
struct Other { g: i32 }
fn mk_ctx(d: u64, val: i32) -> Ctx {
    return .{ .fut = mk_val(d, val) };
}
fn mk_other(v: i32) -> Other { return .{ .g = v }; }
//   g4(cond=true): r = await ctx.fut = 99; inner ctx_local.g = 5; return r + 5 = 104.
async fn g4(ctx: Ctx, cond: bool) -> i32 {
    let r: i32 = await ctx.fut;
    if cond { let cx: Other = mk_other(5); return r + cx.g; }
    return r;
}

export fn async_loop_shadow_run() -> u32 {
    var acc: u32 = 0;
    g_clock = 0;

    // #1 loop-body switch payload 7 thrice (21) + disjoint trailing awaited 50 -> 71.
    var a1: g1__Fut = g1(0, number(7), 3);
    run_to_completion(&a1, tick_idle);
    if g1__Fut_take_result(&a1) == 71 { acc = acc ^ 0x01; }

    // #1 .eof arm (no binding): +1 each iter (3) + trailing awaited 50 -> 53.
    var a1e: g1__Fut = g1(0, eof(), 3);
    run_to_completion(&a1e, tick_idle);
    if g1__Fut_take_result(&a1e) == 53 { acc = acc ^ 0x02; }

    // #2 loop-body p=6 each iter (12) + disjoint trailing p=100 -> 112.
    var a2: g2__Fut = g2(0, 2);
    run_to_completion(&a2, tick_idle);
    if g2__Fut_take_result(&a2) == 112 { acc = acc ^ 0x04; }

    // #3 loop base=6 each iter -> acc=12; tail base = 24.
    var a3: g3__Fut = g3(0, 2);
    run_to_completion(&a3, tick_idle);
    if g3__Fut_take_result(&a3) == 24 { acc = acc ^ 0x08; }

    // #4 carrier no-clobber: param await 99 + inner Other.g 5 = 104.
    var a4: g4__Fut = g4(mk_ctx(0, 99), true);
    run_to_completion(&a4, tick_idle);
    if g4__Fut_take_result(&a4) == 104 { acc = acc ^ 0x10; }

    if acc != 0x1F { return 0; }
    return 1;
}
