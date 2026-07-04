// Findings #1 + #2 (general structured-CFG path): scope-aware capture + alpha-rename of locals that
// live across a suspend point.
//
//   #1 a NON-await local declared INSIDE a nested region (an `if`/`while` block) and read AFTER a
//      later await must be CAPTURED as a `self.*` field. Before the fix it was emitted as a plain
//      local in one poll-state and referenced in a later one -> sema E_UNKNOWN_IDENTIFIER.
//   #2 the SAME source name declared in two DISJOINT scopes must become two DISTINCT fields. Before
//      the fix one field per await-step/binding was appended by name -> E_DUPLICATE_STRUCT_FIELD@0:0.
//
// The transform alpha-renames every local to a unique name (honoring shadowing) and captures all of
// them, so both shapes lower correctly. Asserted deterministically and SENSITIVE to a wrong/garbage
// read: a nested local (`tmp`/`bonus`) contributes to the total, and the reused-name bindings (`r`)
// must each carry their OWN await result — a capture/rename bug (dropped store, aliased field) would
// change the sums. Both backends must agree.

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

// ---- #1: a NESTED non-await local (`tmp`) read AFTER a later await, inside an `if` inside a `while`.
// Routes to the GENERAL path (await nested in if-in-while). `tmp` is computed BEFORE the await and
// read AFTER it; if it were not captured, the post-await read would be a dangling/unknown local.
//   i=0: i<3, tmp = i+100 = 100, r = await(i*10)=0,  acc += r + tmp = 100;  acc += 1 -> 101
//   i=1: tmp=101? NO — tmp = i+100 = 101, r = 10, acc += 10+101=111 -> 101+111=212; +1 -> 213
//   i=2: tmp = 102, r = 20, acc += 20+102=122 -> 335; +1 -> 336
async fn nested_local(d: u64) -> i32 {
    var acc: i32 = 0;
    var i: i32 = 0;
    while i < 3 {
        if i >= 0 {
            let tmp: i32 = i + 100;           // nested non-await local
            let r: i32 = await mk_val(d, i * 10);
            acc = acc + r + tmp;               // tmp read AFTER the await
        }
        acc = acc + 1;
        i = i + 1;
    }
    return acc;
}

// ---- #2: the SAME binding name `r` (and the same nested block-local name `bonus`) declared in TWO
// DISJOINT scopes. Each `r` must carry its own await result; each `bonus` its own value.
//   c=true:  first if:  bonus=7,  r=await(50)=50,  acc += 50+7 = 57
//            second if: bonus=9,  r=await(60)=60,  acc += 60+9 = 69   -> total 126
async fn reused_name(d: u64, c: bool) -> i32 {
    var acc: i32 = 0;
    if c {
        {
            let bonus: i32 = 7;
            acc = acc + bonus;
        }
        let r: i32 = await mk_val(d, 50);
        acc = acc + r;
    }
    if c {
        {
            let bonus: i32 = 9;
            acc = acc + bonus;
        }
        let r: i32 = await mk_val(d, 60);
        acc = acc + r;
    }
    return acc;
}

export fn async_nested_locals_run() -> u32 {
    var acc: u32 = 0;

    // #1: all leaves ready immediately (d=0) -> deterministic 336.
    g_clock = 0;
    var n: nested_local__Fut = nested_local(0);
    run_to_completion(&n, tick_idle);
    if nested_local__Fut_take_result(&n) == 336 { acc = acc ^ 0x1; }

    // #2: reused names across disjoint scopes -> 126; each r/bonus distinct.
    g_clock = 0;
    var rf: reused_name__Fut = reused_name(0, true);
    run_to_completion(&rf, tick_idle);
    if reused_name__Fut_take_result(&rf) == 126 { acc = acc ^ 0x2; }

    // #2 (cond false): neither if-arm runs -> 0 (the disjoint-scope fields stay at their zero-init).
    g_clock = 0;
    var rf0: reused_name__Fut = reused_name(0, false);
    run_to_completion(&rf0, tick_idle);
    if reused_name__Fut_take_result(&rf0) == 0 { acc = acc ^ 0x4; }

    // #1 cancel mid-flight (long deadline keeps the first await pending): reclaims, no leak/garbage.
    g_clock = 0;
    var cn: nested_local__Fut = nested_local(100);
    let p0: bool = nested_local__Fut__poll(&cn);   // parks on the first await (ready@100)
    nested_local__Fut_cancel(&cn);
    let p1: bool = nested_local__Fut__poll(&cn);   // idempotent done
    if !p0 && p1 { acc = acc ^ 0x8; }

    if acc != 0xF { return 0; }
    return 1;
}
