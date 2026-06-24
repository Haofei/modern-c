// Phase E step E2: `await e` where `e` is an ARBITRARY future-valued expression, not only a plain
// named call `g(args)`. The async transform (src/async_lower.zig) now materializes the awaited
// future expression into the state machine's child slot (`self.__cN = <e>`) at the transition that
// begins that await — preserving lazy at-most-one-child-live construction — then polls/takes/cancels
// it via the uniform leaf ABI. This fixture exercises:
//   (1) await of a STRUCT-FIELD future:  `await ctx.fut`  (ctx a param of a known struct type)
//   (2) await of a PARENTHESIZED call:   `await (mk_val(d, v))`
// driven through the executor and asserted deterministically; both backends must agree.

import "std/task.mc";

global g_clock: u64 = 0;
fn tick_idle() -> void { g_clock = g_clock + 1; }

// ---- leaf: ready at `deadline`, yielding `val`; uniform poll/take_result/cancel ABI. ----
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

// A struct that CARRIES a concrete future in a field. Awaiting `ctx.fut` must copy this leaf
// future into the generated child slot and drive it there.
struct Ctx { fut: ValFut, bias: i32 }
fn mk_ctx(deadline: u64, val: i32, bias: i32) -> Ctx {
    var c: Ctx = uninit;
    c.fut = mk_val(deadline, val);
    c.bias = bias;
    return c;
}

// (1) await of a struct-FIELD future. `ctx` is a parameter whose type `Ctx` is syntactically
// known, so the awaited field `ctx.fut`'s future type (`ValFut`) is resolvable pre-sema.
async fn await_field(ctx: Ctx) -> i32 {
    let r: i32 = await ctx.fut;
    return r + ctx.bias;
}

// (2) await of a PARENTHESIZED call expression — must unwrap the grouping and drive the call.
async fn await_grouped(d: u64, v: i32) -> i32 {
    let r: i32 = await (mk_val(d, v));
    return r;
}

export fn async_await_expr_run() -> u32 {
    var acc: u32 = 0;

    // (1) field-future await: ready at clock 2, value 30, bias +5 -> 35.
    g_clock = 0;
    var ff: await_field__Fut = await_field(mk_ctx(2, 30, 5));
    let a0: bool = await_field__Fut__poll(&ff);   // clock 0: child pending
    tick_idle(); tick_idle();                      // clock 2
    let a1: bool = await_field__Fut__poll(&ff);   // child ready -> completes
    if !a0 && a1 && await_field__Fut_take_result(&ff) == 35 { acc = acc ^ 0x1; }

    // (2) grouped-call await: ready at clock 1, value 77.
    g_clock = 0;
    var gf: await_grouped__Fut = await_grouped(1, 77);
    let b0: bool = await_grouped__Fut__poll(&gf);  // clock 0: pending
    tick_idle();                                    // clock 1
    let b1: bool = await_grouped__Fut__poll(&gf);  // ready
    if !b0 && b1 && await_grouped__Fut_take_result(&gf) == 77 { acc = acc ^ 0x2; }

    // (3) cancel of a still-pending field-future await reclaims the active child (no double-free):
    // poll once (pending), cancel, then a subsequent poll is an idempotent no-op completion.
    g_clock = 0;
    var cf: await_field__Fut = await_field(mk_ctx(9, 1, 0));
    let c0: bool = await_field__Fut__poll(&cf);    // pending
    await_field__Fut_cancel(&cf);                  // walk active child, mark done
    let c1: bool = await_field__Fut__poll(&cf);    // idempotent: already done -> true
    if !c0 && c1 { acc = acc ^ 0x4; }

    if acc != 0x7 { return 0; }
    return 1;
}
