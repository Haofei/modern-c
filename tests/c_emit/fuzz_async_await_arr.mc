// Phase E step E2 (follow-up, finding #3): `await arr[i]` — an ARRAY-ELEMENT future await whose
// base is a param/field of array-of-future type. The E_ASYNC_AWAIT_UNRESOLVED message promises this
// shape; before the fix only a struct-field array element resolved, while a DIRECT array PARAM
// element (`futs: [N]ValFut`, `await futs[i]`) was rejected because the param's type name was only
// recorded when it was a bare `name` (an array param's type is `array`, so it was dropped). The
// fix records each param under its CARRIER type — peeling pointer/qualifier wrappers and mapping an
// array param to its ELEMENT type — so `await futs[i]` resolves to the element future type without
// sema, exactly as a struct's array FIELD already did.
//
// Exercised here:
//   (1) await of a DIRECT array PARAM element:  `await futs[i]`   (futs: [4]ValFut)
//   (2) await of a STRUCT-FIELD array element:  `await c.arr[j]`  (c: *mut Ctx, Ctx.arr: [3]ValFut)
// The selected element's value must flow to the result, so awaiting the WRONG element (a resolution
// bug picking a different field/type) would fail the asserted totals. Both backends must agree.

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

// (1) await of a DIRECT array-PARAM element. `futs` is a param of array-of-future type, so
// `futs[i]`'s element future type (`ValFut`) is now resolvable pre-sema via the carrier mapping.
async fn await_param_idx(futs: [4]ValFut, i: usize) -> i32 {
    let r: i32 = await futs[i];
    return r;
}

// A struct carrying an ARRAY of concrete futures in a field.
struct Ctx { arr: [3]ValFut, bias: i32 }

// (2) await of a STRUCT-FIELD array element via a pointer param `c` (`c.arr[j]`). The pointer is
// peeled to the struct carrier `Ctx`, then the array field `arr` to its element type `ValFut`.
async fn await_field_idx(c: *mut Ctx, j: usize) -> i32 {
    let r: i32 = await c.arr[j];
    return r + c.bias;
}

export fn async_await_arr_run() -> u32 {
    var acc: u32 = 0;

    // (1) DIRECT array param: pick element 2 (value 30, ready@2). Wrong-element bugs miss 30.
    g_clock = 0;
    var fs: [4]ValFut = uninit;
    fs[0] = mk_val(1, 10);
    fs[1] = mk_val(1, 20);
    fs[2] = mk_val(2, 30);
    fs[3] = mk_val(1, 40);
    var pf: await_param_idx__Fut = await_param_idx(fs, 2);
    let a0: bool = await_param_idx__Fut__poll(&pf);   // clock 0: element 2 pending (ready@2)
    tick_idle(); tick_idle();                          // clock 2
    let a1: bool = await_param_idx__Fut__poll(&pf);   // ready -> completes
    if !a0 && a1 && await_param_idx__Fut_take_result(&pf) == 30 { acc = acc ^ 0x1; }

    // (2) STRUCT-FIELD array element via pointer: element 1 (value 55, ready@1), bias +4 -> 59.
    g_clock = 0;
    var ctx: Ctx = uninit;
    ctx.arr[0] = mk_val(1, 11);
    ctx.arr[1] = mk_val(1, 55);
    ctx.arr[2] = mk_val(1, 99);
    ctx.bias = 4;
    var bf: await_field_idx__Fut = await_field_idx(&ctx, 1);
    let b0: bool = await_field_idx__Fut__poll(&bf);   // clock 0: pending
    tick_idle();                                       // clock 1
    let b1: bool = await_field_idx__Fut__poll(&bf);   // ready
    if !b0 && b1 && await_field_idx__Fut_take_result(&bf) == 59 { acc = acc ^ 0x2; }

    // (3) cancel of a still-pending array-element await reclaims the active child (no double-free).
    g_clock = 0;
    var cfs: [4]ValFut = uninit;
    cfs[0] = mk_val(9, 1);
    cfs[1] = mk_val(9, 2);
    cfs[2] = mk_val(9, 3);
    cfs[3] = mk_val(9, 4);
    var cf: await_param_idx__Fut = await_param_idx(cfs, 0);
    let c0: bool = await_param_idx__Fut__poll(&cf);   // pending (ready@9)
    await_param_idx__Fut_cancel(&cf);                  // walk active child, mark done
    let c1: bool = await_param_idx__Fut__poll(&cf);   // idempotent: already done -> true
    if !c0 && c1 { acc = acc ^ 0x4; }

    if acc != 0x7 { return 0; }
    return 1;
}
