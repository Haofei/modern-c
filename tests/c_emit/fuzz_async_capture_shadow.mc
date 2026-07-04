// ROOT-CAUSE coverage (src/async_lower.zig): the fast paths build the future-struct's CAPTURED
// fields BY ORIGINAL binding name from three sources — params, pre-REGION (pre-branch/pre-loop)
// top-level locals, and awaited bindings. When the SAME source name is reused for two captured
// bindings (a local AND an awaited binding, or the same name across two disjoint regions), the fast
// path emitted TWO struct fields of that name (E_DUPLICATE_STRUCT_FIELD) and/or resolved an
// `await x.fut` through the FIRST-writer carrier (the wrong type) instead of the binding actually in
// scope (E_RETURN_TYPE_MISMATCH) — both broken-generated-struct errors on VALID shadowing source.
// FIX: `fastPathCaptureCollision` routes any such capture-name collision to the alpha-renaming general
// path, where every local gets a globally-unique name so neither a duplicate field nor a carrier
// mis-resolution is possible.
//
// IMPORTANT — this exercises only LOCALLY-VALID shadowing (the kind ordinary MC accepts): the SAME
// source name reused across DISJOINT lexical scopes (two separate `if` arms / loop body), NOT a local
// re-binding a still-live enclosing binding (e.g. a body-top-level local shadowing a param, or a
// second `let` of a live name in one scope). Those latter shapes are E_DUPLICATE_LOCAL — see
// tests/c_emit/bad/async_duplicate_local.mc — and async fns now reject them exactly as non-async fns
// do (src/async_lower.zig validateNoDuplicateLocals).
//
// VALUE-SENSITIVE: in every case the two same-named bindings carry DISTINCT values (and, for the
// carrier cases, DISTINCT struct types), so a pre-fix duplicate-field clobber or carrier mis-resolution
// would change the result. On the pre-fix tree these fns don't even COMPILE (duplicate field +
// return-type mismatch), so this whole fixture failed to build before the routing fix.

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

// Two DISTINCT carrier struct types holding a ValFut, so the SAME source name reused for carriers of
// different types in disjoint scopes has a genuinely different carrier type per use (the duplicate-
// field + carrier-mismatch trigger).
struct Ctx   { fut: ValFut }            // carrier A
struct Other { fut: ValFut, g: i32 }    // carrier B (extra field — distinct type)

fn mk_ctx(d: u64, v: i32) -> Ctx { return .{ .fut = mk_val(d, v) }; }
fn mk_other(d: u64, v: i32, g: i32) -> Other {
    return .{ .fut = mk_val(d, v), .g = g };
}

// ---- (1) The SAME local name `cx` names carriers of DIFFERENT types in two DISJOINT `if` blocks, each
// awaited over its own carrier. This is valid lexical shadowing (the two `cx` live in disjoint scopes).
// Pre-fix the fast path emitted two fields named `cx` (E_DUPLICATE_STRUCT_FIELD) and resolved
// `await cx.fut` through the first-writer carrier (E_RETURN_TYPE_MISMATCH). Each block must read ITS
// OWN carrier's future, so the values differ per branch.
//   c1(cond=true):  cx: Other fut=777, g=9 -> await 777, out = 777 + 9 = 786.
//   c1(cond=false): cx: Ctx   fut=100      -> await 100, out = 100.
async fn c1(cond: bool) -> i32 {
    var out: i32 = 0;
    if cond {
        let cx: Other = mk_other(0, 777, 9);
        let r: i32 = await cx.fut;
        out = r + cx.g;
    }
    if !cond {
        let cx: Ctx = mk_ctx(0, 100);
        let r: i32 = await cx.fut;
        out = r;
    }
    return out;
}

// ---- (2) A local carrier `cx` (Other) awaited each loop iteration in ONE `if` block, AND a same-named
// local `cx` (Ctx) in a DISJOINT trailing `if`. Each `cx` lives only inside its own block (disjoint
// scopes — valid shadowing), and is a distinct field of a distinct type. The looping block awaits the
// Other carrier's fut (11) + g (3) per iteration; the trailing block awaits the Ctx carrier's fut (200).
//   c2(n=2, cond=true):  2 * (11 + 3) + 200 = 228.
//   c2(n=0, cond=false): looping block skipped, trailing block skipped -> 0.
async fn c2(n: i32, cond: bool) -> i32 {
    var acc: i32 = 0;
    if cond {
        let cx: Other = mk_other(0, 11, 3);
        var i: i32 = 0;
        while i < n {
            let r: i32 = await cx.fut;
            acc = acc + r + cx.g;
            i = i + 1;
        }
    }
    if cond {
        let cx: Ctx = mk_ctx(0, 200);
        let r: i32 = await cx.fut;
        acc = acc + r;
    }
    return acc;
}

// ---- (3) The SAME awaited-binding name `p` in two DISJOINT `if` blocks, each carrying its OWN await
// result. Pre-fix both became a struct field named `p` -> E_DUPLICATE_STRUCT_FIELD; each `p` must
// read ITS OWN awaited value.
//   c3(cond=true):  p = await 55; return p + 1 = 56.
//   c3(cond=false): p = await 70; return p + 2 = 72.
async fn c3(cond: bool) -> i32 {
    var out: i32 = 0;
    if cond {
        let p: i32 = await mk_val(0, 55);
        out = p + 1;
    }
    if !cond {
        let p: i32 = await mk_val(0, 70);
        out = p + 2;
    }
    return out;
}

// ---- (4) LOCAL-vs-LOCAL: the SAME source name `acc` is used in two DISJOINT `if` arms (valid lexical
// shadowing — the two `acc` live in disjoint scopes, neither re-binds a still-live outer `acc`). The
// outer accumulator is named `total`; each arm's `acc` is captured as its OWN distinct field with its
// own value. Pre-fix two fields named `acc` -> E_DUPLICATE_STRUCT_FIELD.
//   c4(cond=true):  arm-true:  acc = 5;  r = await 40; total = (40 + 5) = 45.
//   c4(cond=false): arm-false: acc = 7;  r = await 30; total = (30 + 7) = 37.
async fn c4(cond: bool) -> i32 {
    var total: i32 = 0;
    if cond {
        let acc: i32 = 5;
        let r: i32 = await mk_val(0, 40);
        total = r + acc;
    }
    if !cond {
        let acc: i32 = 7;
        let r: i32 = await mk_val(0, 30);
        total = r + acc;
    }
    return total;
}

export fn async_capture_shadow_run() -> u32 {
    var passmask: u32 = 0;
    g_clock = 0;

    // (1) disjoint-arm same-name carriers of distinct types: true arm -> 777 + 9 = 786.
    var a1: c1__Fut = c1(true);
    run_to_completion(&a1, tick_idle);
    if c1__Fut_take_result(&a1) == 786 { passmask = passmask ^ 0x01; }

    // (1b) false arm: the OTHER same-named carrier (Ctx, fut=100) -> 100.
    var a1e: c1__Fut = c1(false);
    run_to_completion(&a1e, tick_idle);
    if c1__Fut_take_result(&a1e) == 100 { passmask = passmask ^ 0x02; }

    // (2) pre-loop carrier each iter (11+3) plus trailing disjoint arm (200): 28 + 200 = 228.
    var a2: c2__Fut = c2(2, true);
    run_to_completion(&a2, tick_idle);
    if c2__Fut_take_result(&a2) == 228 { passmask = passmask ^ 0x04; }

    // (2b) zero-iteration loop, trailing arm skipped: acc stays 0.
    var a2z: c2__Fut = c2(0, false);
    run_to_completion(&a2z, tick_idle);
    if c2__Fut_take_result(&a2z) == 0 { passmask = passmask ^ 0x08; }

    // (3) same awaited-binding name `p` in disjoint arms: true -> 55 + 1 = 56.
    var a3: c3__Fut = c3(true);
    run_to_completion(&a3, tick_idle);
    if c3__Fut_take_result(&a3) == 56 { passmask = passmask ^ 0x10; }

    // (3b) false arm reads its OWN awaited value: 70 + 2 = 72.
    var a3e: c3__Fut = c3(false);
    run_to_completion(&a3e, tick_idle);
    if c3__Fut_take_result(&a3e) == 72 { passmask = passmask ^ 0x20; }

    // (4) local-vs-local reused name `acc` in disjoint arms: true -> 40 + 5 = 45.
    var a4: c4__Fut = c4(true);
    run_to_completion(&a4, tick_idle);
    if c4__Fut_take_result(&a4) == 45 { passmask = passmask ^ 0x40; }

    // (4b) false arm: the OTHER reused-name `acc` (7): 30 + 7 = 37.
    var a4e: c4__Fut = c4(false);
    run_to_completion(&a4e, tick_idle);
    if c4__Fut_take_result(&a4e) == 37 { passmask = passmask ^ 0x80; }

    if passmask != 0xFF { return 0; }
    return 1;
}
