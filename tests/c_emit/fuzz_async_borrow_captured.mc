// Phase E step E4: the v0.5 borrow-across-await relaxation (POLL-FORMED captured borrow).
//
// What E4 ALLOWS: a reference to a CAPTURED local (a future state field) held across an `await`
// PROVIDED the borrow is formed in the POLL MACHINE — at the stable `*mut self` the driver polls in
// place, NOT in the by-value CONSTRUCTOR (where `&self.field` dangles after the move). Because every
// poll re-enters through the same `*mut self`, a `&self.field` formed in poll-state N is still valid
// in poll-state N+1: the field lives in the future and the future does not move between polls. Two
// poll-formed shapes are proven sound here and pinned by this gate:
//   (A) LOOP-body borrow: `let p = &acc;` formed inside the loop body (after the iteration's await),
//       dereferenced across the BACK-EDGE in the next iteration — the loop lowering emits the body
//       straight-line into a poll state, so `&self.acc` is taken at the stable address.
//   (B) PRE-BRANCH borrow: `let p = &acc;` before an await-bearing if/else — the branch lowering
//       REPLAYS the pre-branch straight-line into the poll machine (the dispatch state, at stable
//       `*mut self`), not the constructor, so `&self.acc` is sound across both arms' awaits.
//
// What stays REJECTED (kept fail-closed): a PRE-LOOP borrow `let p = &x;` before an await-bearing
// `while` — the loop lowering replays the pre-loop straight-line in the by-value CONSTRUCTOR, so
// `&self.x` there dangles after the move (tests/c_emit/bad/async_borrow_across_await.mc) — and a
// self-referential / pinned first-await-arg borrow (tests/c_emit/bad/async_borrow_pinning.mc). The
// pre-loop case is conservatively rejected (it COULD be made sound by replaying into the loop head
// like the branch lowering does, but that is deferred — E4 stays fail-closed there).
//
// Soundness sensitivity: the body forms `let p = &acc;` AFTER the iteration's await, writes the
// running total THROUGH `p`, then the NEXT iteration READS `*p` AFTER ITS OWN await — so the read
// of `*p` is genuinely separated from the write by a suspend (the back-edge + the next await). The
// total lives ONLY in the field reached via `*p`; it is never updated through `acc` directly. If `p`
// pointed anywhere but the live `self.acc` (a dangling / wrong address), the next iteration's `*p`
// read would not observe the prior write and the asserted sums would be wrong. So the totals below
// are sensitive to a dangling / wrong-address borrow, not just a happy path.
//
// Entry-mode contract: returns 1 iff every check passes; both backends must agree.

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

// `acc` is a captured pre-loop local, but the BORROW `p = &acc` is formed INSIDE the loop body
// (after the await), and used to READ/WRITE the running total across the back-edge into the next
// iteration's await. The accumulation flows entirely through `*p`.
async fn sum_via_borrow(n: i32, d: u64) -> i32 {
    var acc: i32 = 0;
    var i: i32 = 0;
    while i < n {
        let v: i32 = await mk_val(d, i * 10);   // suspend point
        let p: *mut i32 = &acc;       // borrow of a captured field, FORMED IN THE POLL MACHINE
        let cur: i32 = *p;            // READ the running total THROUGH the borrow
        let nv: i32 = cur + v;
        *p = nv;                      // WRITE it back THROUGH the borrow (lives across the back-edge)
        i = i + 1;
    }
    return acc;                       // observes what the borrow wrote into the live field
}

// (B) PRE-BRANCH captured borrow: `p = &acc` formed before an await-bearing if/else. The branch
// lowering replays the pre-branch straight-line (including this borrow-init) into the poll machine at
// the stable `*mut self` — so `*p` written inside the taken arm, ACROSS that arm's await, lands in
// the live field and is observed by the final `acc` read. A dangling `p` would lose the write.
async fn branch_via_borrow(d: u64, cond: bool) -> i32 {
    var acc: i32 = 100;
    let p: *mut i32 = &acc;           // borrow of a captured field, replayed into the poll machine
    if cond {
        let r: i32 = await mk_val(d, 5);
        let nv: i32 = *p + r;         // read+write the live field THROUGH the borrow, across the await
        *p = nv;
    } else {
        let r2: i32 = await mk_val(d, 9);
        let nv2: i32 = *p + r2;
        *p = nv2;
    }
    return acc;
}

export fn async_borrow_captured_run() -> u32 {
    var acc: u32 = 0;

    // n=4, d=1: v = 0,10,20,30 accumulated through `p`. sum = 60.
    g_clock = 0;
    var f1: sum_via_borrow__Fut = sum_via_borrow(4, 1);
    run_to_completion(&f1, tick_idle);
    if sum_via_borrow__Fut_take_result(&f1) == 60 { acc = acc ^ 0x1; }

    // n=6, d=2: v = 0,10,20,30,40,50. sum = 150. Larger deadline => more polls between mutations.
    g_clock = 0;
    var f2: sum_via_borrow__Fut = sum_via_borrow(6, 2);
    run_to_completion(&f2, tick_idle);
    if sum_via_borrow__Fut_take_result(&f2) == 150 { acc = acc ^ 0x2; }

    // Zero-iteration loop: borrow never formed; result stays the initial 0.
    g_clock = 0;
    var f3: sum_via_borrow__Fut = sum_via_borrow(0, 1);
    run_to_completion(&f3, tick_idle);
    if sum_via_borrow__Fut_take_result(&f3) == 0 { acc = acc ^ 0x4; }

    // (B) pre-branch borrow, THEN arm: 100 + 5 = 105 written through `*p` across the await.
    g_clock = 0;
    var b1: branch_via_borrow__Fut = branch_via_borrow(1, true);
    run_to_completion(&b1, tick_idle);
    if branch_via_borrow__Fut_take_result(&b1) == 105 { acc = acc ^ 0x8; }

    // (B) pre-branch borrow, ELSE arm: 100 + 9 = 109 written through `*p` across the await.
    g_clock = 0;
    var b2: branch_via_borrow__Fut = branch_via_borrow(1, false);
    run_to_completion(&b2, tick_idle);
    if branch_via_borrow__Fut_take_result(&b2) == 109 { acc = acc ^ 0x10; }

    if acc != 0x1F { return 0; }
    return 1;
}
