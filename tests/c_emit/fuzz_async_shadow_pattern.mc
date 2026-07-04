// Finding #1 (SILENT MISCOMPILATION) + #2 (fn-pointer callee rebase) + #3 (local carrier await),
// all in the async transform (src/async_lower.zig). VALUE-SENSITIVE: each assertion would FAIL on
// the pre-fix tree, where the wrong binding was read silently.
//
//   #1 a `switch` arm pattern (`number(x) => ...`) introduces a REAL arm-local; a same-named binding
//      `x` lives in a DISJOINT scope (a separate await-bearing `if`). Pre-fix the identifier rewriters
//      rewrote the in-arm `x` to `self->x` (the disjoint captured field) instead of the arm payload
//      local — silently reading the WRONG value. Covered on BOTH the fast path and the general path.
//      (NOTE: the arm payload may NOT shadow a STILL-LIVE same-named binding — that is E_DUPLICATE_LOCAL
//      in ordinary MC and async fns now reject it identically; see bad/async_duplicate_local.mc. So the
//      same-named binding is placed in a DISJOINT scope, the only locally-valid form of this collision.)
//   #2 a captured fn-pointer param used as a CALLEE after an await (`op(x, y)`) was left as `op(...)`
//      instead of `self->op(...)` -> E_UNKNOWN_FUNCTION. Covered fast + general.
//   #3 `await ctx.fut` where `ctx` is an explicitly-typed LOCAL carrier (not a param) now resolves
//      (general path) — pre-fix structTypeOf knew only params -> E_ASYNC_AWAIT_UNRESOLVED.

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

fn add2(a: i32, b: i32) -> i32 { return a + b; }

// ---- #1 FAST path: an arm payload `x` whose name is reused (disjointly) by a binding `x` in a
// SEPARATE scope (a leading await-bearing `if`). The leading `if` awaits into a disjoint-scope `x`
// (= 42) accumulated into `a`; the `switch` is the await-free tail, where the `number(x)` arm must read
// its PAYLOAD (not the disjoint awaited `x`'s captured field).
//   f1(t=number(7)): a = (await 42); arm reads payload x=7, returns payload x + a = 7 + 42 = 49.
//   A pre-fix read of the disjoint awaited `self->x` for the payload would give 42 + 42 = 84.
async fn f1(d: u64, t: Token) -> i32 {
    var a: i32 = 0;
    if a == 0 {
        let x: i32 = await mk_val(d, 42);
        a = x;
    }
    switch t {
        number(x) => { return x + a; },
        .eof => { return a; },
    }
}

// ---- #1 GENERAL path: arm payload `x` reused (disjointly) by an awaited binding `x` that lives in a
// SEPARATE await-bearing `if`. Two await-bearing ifs force the general structured-CFG path (alpha-
// renamer). The `number(x)` arm must read the PAYLOAD; the awaited `x` is captured as its own field.
//   f2(t=number(7)): if-block awaits into x (=42, disjoint scope); arm number returns payload 7.
//   f2(t=eof):       .eof has no binding -> returns the running total (awaited 42).
//   Pre-fix: `number(x)` returned the awaited capture (42), NOT the payload 7.
async fn f2(d: u64, t: Token, cond: bool) -> i32 {
    var total: i32 = 0;
    if cond {
        let x: i32 = await mk_val(d, 42);
        total = total + x;
    }
    if cond { let w: i32 = await mk_val(d, 1); }
    switch t {
        number(x) => { return x; },
        .eof => { return total; },
    }
}

// ---- #2 FAST path: a captured fn-pointer PARAM `op` called after the await.
//   f3(op=add2): a = await(42); return op(a, 8) = 50.
async fn f3(d: u64, op: fn(i32, i32) -> i32, cond: bool) -> i32 {
    let a: i32 = await mk_val(d, 42);
    if cond { let z: i32 = await mk_val(d, 0); return op(a, z); }
    return op(a, 8);
}

// ---- #2 GENERAL path: fn-pointer callee after an await, two await-ifs force general.
//   f4(op=add2): a = await(42); return op(a, 8) = 50.
async fn f4(d: u64, op: fn(i32, i32) -> i32, cond: bool) -> i32 {
    let a: i32 = await mk_val(d, 42);
    if cond { let z: i32 = await mk_val(d, 0); }
    if cond { let w: i32 = await mk_val(d, 0); }
    return op(a, 8);
}

// ---- #3 GENERAL path: `await ctx.fut` where `ctx` is an explicitly-typed LOCAL carrier.
struct Ctx { fut: ValFut }
fn mk_ctx(d: u64, val: i32) -> Ctx {
    return .{ .fut = mk_val(d, val) };
}
//   f5: ctx = mk_ctx(99); v = await ctx.fut = 99; two await-ifs force general; return v = 99.
async fn f5(d: u64, cond: bool) -> i32 {
    let ctx: Ctx = mk_ctx(d, 99);
    let v: i32 = await ctx.fut;
    if cond { let z: i32 = await mk_val(d, 0); }
    if cond { let w: i32 = await mk_val(d, 0); }
    return v;
}

export fn async_shadow_pattern_run() -> u32 {
    var acc: u32 = 0;
    g_clock = 0;

    // #1 fast: arm payload 7 + 42 = 49 (NOT awaited x=42 read for the payload -> 84).
    var a1: f1__Fut = f1(0, number(7));
    run_to_completion(&a1, tick_idle);
    if f1__Fut_take_result(&a1) == 49 { acc = acc ^ 0x01; }

    // #1 fast .eof arm: no payload, returns the awaited x = 42.
    var a1e: f1__Fut = f1(0, eof());
    run_to_completion(&a1e, tick_idle);
    if f1__Fut_take_result(&a1e) == 42 { acc = acc ^ 0x02; }

    // #1 general: number arm reads PAYLOAD 7 (NOT awaited 42).
    var a2: f2__Fut = f2(0, number(7), true);
    run_to_completion(&a2, tick_idle);
    if f2__Fut_take_result(&a2) == 7 { acc = acc ^ 0x04; }

    // #1 general .eof arm: no binding, reads awaited x = 42.
    var a2e: f2__Fut = f2(0, eof(), true);
    run_to_completion(&a2e, tick_idle);
    if f2__Fut_take_result(&a2e) == 42 { acc = acc ^ 0x08; }

    // #2 fast: captured fn-ptr callee -> op(42, 8) = 50.
    var a3: f3__Fut = f3(0, add2, false);
    run_to_completion(&a3, tick_idle);
    if f3__Fut_take_result(&a3) == 50 { acc = acc ^ 0x10; }

    // #2 general: op(42, 8) = 50.
    var a4: f4__Fut = f4(0, add2, true);
    run_to_completion(&a4, tick_idle);
    if f4__Fut_take_result(&a4) == 50 { acc = acc ^ 0x20; }

    // #3 general: local carrier await -> 99.
    var a5: f5__Fut = f5(0, true);
    run_to_completion(&a5, tick_idle);
    if f5__Fut_take_result(&a5) == 99 { acc = acc ^ 0x40; }

    if acc != 0x7F { return 0; }
    return 1;
}
