// Phase E step E3c: MULTIPLE await-bearing constructs in ONE async fn — an await-bearing `if`/`else`
// FOLLOWED BY an await-bearing `while` loop, with a leading await before them. The flat per-construct
// state allocator rejected this (E_ASYNC_BRANCH_UNSUPPORTED / E_ASYNC_LOOP_UNSUPPORTED: at most one
// await-bearing construct). E3c lowers the whole body as one structured CFG over a single
// `while true { switch state }` dispatch: the if's two arms each get their own poll-states converging on
// a JOIN state, the join flows into the loop head, the loop body suspends and back-edges to its head, and
// the loop exit flows into the tail. Each `await` is its own poll-state; each child is built on the entry
// edge (built-once-per-entry); a re-poll never rebuilds.
//
// Soundness probed: g_open (live-slot counter) must return to 0 (no leak / double-free); the sequencing
// of three independent await-bearing regions in one fn must not leave a stale child live across the
// boundary between regions (the if-join must have taken the arm's child before the loop head builds the
// loop child). The cancel checks park mid-loop AFTER the if region completed and assert exactly one live
// slot, then zero.
//
// Entry-mode contract: returns 1 iff every check passes; both backends must agree.

import "std/task.mc";

global g_clock: u64 = 0;
fn tick_idle() -> void { g_clock = g_clock + 1; }

global g_open: i32 = 0;
struct ValFut { deadline: u64, val: i32, held: bool }
fn mk_val(deadline: u64, val: i32) -> ValFut {
    var f: ValFut = uninit;
    f.deadline = deadline;
    f.val = val;
    f.held = true;
    g_open = g_open + 1;
    return f;
}
impl Future for ValFut {
    fn poll(self: *mut ValFut) -> bool {
        if g_clock >= self.deadline {
            if self.held { self.held = false; g_open = g_open - 1; }
            return true;
        }
        return false;
    }
    fn cancel(self: *mut ValFut) -> void {
        if self.held { self.held = false; g_open = g_open - 1; }
    }
}
fn ValFut_take_result(self: *mut ValFut) -> i32 { return self.val; }
fn ValFut_cancel(self: *mut ValFut) -> void {
    if self.held { self.held = false; g_open = g_open - 1; }
}

// ---- leading await, THEN an await-bearing if/else, THEN an await-bearing while ----
// base = await (=5). Then a branch on `sel`: then-arm awaits +100, else-arm awaits +200, both store into
// `pick`. Then a loop summing j*10 for j in 0..k, each iteration awaiting. Result = pick + loop_sum.
//   sel=true:  pick = base + 100 = 105
//   sel=false: pick = base + 200 = 205
//   loop k=3:  0 + 10 + 20 = 30
async fn multi(sel: bool, k: i32, d: u64) -> i32 {
    let base: i32 = await mk_val(d, 5);
    var pick: i32 = 0;
    if sel {
        let t: i32 = await mk_val(d, 100);
        pick = base + t;
    } else {
        let e: i32 = await mk_val(d, 200);
        pick = base + e;
    }
    var sum: i32 = 0;
    var j: i32 = 0;
    while j < k {
        let v: i32 = await mk_val(d, j * 10);
        sum = sum + v;
        j = j + 1;
    }
    return pick + sum;
}

export fn async_multi_construct_run() -> u32 {
    var acc: u32 = 0;

    // sel=true, k=3: 105 + 30 = 135.
    g_clock = 0; g_open = 0;
    var ft: multi__Fut = multi(true, 3, 1);
    run_to_completion(&ft, tick_idle);
    if multi__Fut_take_result(&ft) == 135 { acc = acc ^ 0x1; }
    if g_open == 0 { acc = acc ^ 0x2; }

    // sel=false, k=3: 205 + 30 = 235.
    g_clock = 0; g_open = 0;
    var fe: multi__Fut = multi(false, 3, 1);
    run_to_completion(&fe, tick_idle);
    if multi__Fut_take_result(&fe) == 235 { acc = acc ^ 0x4; }
    if g_open == 0 { acc = acc ^ 0x8; }

    // k=0: the loop never runs (its child is never built); sel=true -> 105 + 0 = 105.
    g_clock = 0; g_open = 0;
    var fz: multi__Fut = multi(true, 0, 1);
    run_to_completion(&fz, tick_idle);
    if multi__Fut_take_result(&fz) == 105 { acc = acc ^ 0x10; }
    if g_open == 0 { acc = acc ^ 0x20; }

    // CANCEL parked on the LEADING await (state for `base`): nothing built yet beyond it.
    g_clock = 0; g_open = 0;
    var fc: multi__Fut = multi(true, 3, 100);                 // all awaits ready@100, never in window
    let c0: bool = multi__Fut__poll(&fc);                     // build base child, park
    if !c0 && g_open == 1 { acc = acc ^ 0x40; }
    multi__Fut_cancel(&fc);
    if g_open == 0 { acc = acc ^ 0x80; }
    let c1: bool = multi__Fut__poll(&fc);
    if c1 && g_open == 0 { acc = acc ^ 0x100; }

    // CANCEL parked INSIDE the loop, AFTER the leading await + the if region both completed: outer awaits
    // ready@1 (base + the chosen arm), the loop await never ready (d split). Prove exactly one live slot
    // (the loop child) — i.e. the if-arm child was already taken, not still live — then cancel to zero.
    g_clock = 0; g_open = 0;
    var fl: multi_split__Fut = multi_split(true, 3, 1, 50);   // base+arm ready@1, loop ready@50
    let l0: bool = multi_split__Fut__poll(&fl);               // run base + then-arm, enter loop, park on v
    if !l0 && g_open == 1 { acc = acc ^ 0x200; }              // ONLY the loop child is live
    multi_split__Fut_cancel(&fl);
    if g_open == 0 { acc = acc ^ 0x400; }
    let l1: bool = multi_split__Fut__poll(&fl);
    if l1 && g_open == 0 { acc = acc ^ 0x800; }

    if acc != 0xFFF { return 0; }
    return 1;
}

// Variant with split deadlines so a cancel can park precisely on the loop await (after the if region).
async fn multi_split(sel: bool, k: i32, dpre: u64, dloop: u64) -> i32 {
    let base: i32 = await mk_val(dpre, 5);
    var pick: i32 = 0;
    if sel {
        let t: i32 = await mk_val(dpre, 100);
        pick = base + t;
    } else {
        let e: i32 = await mk_val(dpre, 200);
        pick = base + e;
    }
    var sum: i32 = 0;
    var j: i32 = 0;
    while j < k {
        let v: i32 = await mk_val(dloop, j * 10);
        sum = sum + v;
        j = j + 1;
    }
    return pick + sum;
}
