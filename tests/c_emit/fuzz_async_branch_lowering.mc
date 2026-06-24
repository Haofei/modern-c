// Phase D, build-order step 4: the EXACT MC the async-fn -> stackless-state-machine transform
// should GENERATE for an `await` inside an `if`/`else`. Each branch gets its OWN state range; both
// ranges advance to a COMMON continuation state. Written by hand as the acceptance target; driving
// it through the Phase-A executor and diffing C vs LLVM proves the branch lowering is identical on
// both backends. When the transform grows branches, its output must match fixtures of this shape.
//
// State layout for `let base = await e0; if sel { let a = await eT; out=base+a } else { let b =
// await eE; out=base+b } return out;`:
//   state 0       : pre-branch await e0 -> base; then DISPATCH (build the taken child lazily,
//                   set state to the then-entry (1) or the else-entry (2)).
//   state 1 (then): await eT -> a; out=base+a; -> continuation (state 3).
//   state 2 (else): await eE -> b; out=base+b; -> continuation (state 3).
//   state 3 (cont): tail -> result=out; -> DONE (state 4).
//   state 4       : DONE.
// The sequential `if self.state == N` fall-through is correct: a branch's exit jumps straight to
// the continuation (state 3, beyond both branch states), so the untaken branch's block never runs.

import "std/task.mc";

global g_clock: u64 = 0;
fn tick_idle() -> void { g_clock = g_clock + 1; }

// cancellable leaf with a slot counter (uniform leaf ABI: __poll + _take_result + _cancel).
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
    fn cancel(self: *mut ValFut) -> void { if self.held { self.held = false; g_open = g_open - 1; } }  // E1
}
fn ValFut_take_result(self: *mut ValFut) -> i32 { return self.val; }
fn ValFut_cancel(self: *mut ValFut) -> void { if self.held { self.held = false; g_open = g_open - 1; } }

// ---- generated for `async fn pick(sel, dt, de) -> i32 {
//        let base = await mk_val(1, 10);
//        var out: i32 = 0;
//        if sel { let a = await mk_val(dt, 100); out = base + a; }
//        else   { let b = await mk_val(de, 200); out = base + b; }
//        return out; }` ----
// Both branch children share no field — only the TAKEN branch's child is ever built (lazy), so one
// field per branch await. `base` is live across the branch -> a captured field.
struct pick__Fut {
    state: u8,
    __c0: ValFut,   // pre-branch await
    __cT: ValFut,   // then-branch await (built only if sel)
    __cE: ValFut,   // else-branch await (built only if !sel)
    sel: bool, dt: u64, de: u64,
    base: i32, out: i32,
    result: i32,
}
fn pick(sel: bool, dt: u64, de: u64) -> pick__Fut {
    var self: pick__Fut = uninit;
    self.state = 0;
    self.sel = sel;
    self.dt = dt;
    self.de = de;
    self.__c0 = mk_val(1, 10);   // pre-branch child built eagerly (no dependency)
    self.base = 0;
    self.out = 0;
    self.result = 0;
    return self;
}
impl Future for pick__Fut {
    fn poll(self: *mut pick__Fut) -> bool {
        if self.state == 4 { return true; }            // DONE
        if self.state == 0 {
            let r: bool = ValFut.poll(&self.__c0);
            if !r { return false; }
            self.base = ValFut_take_result(&self.__c0);
            // DISPATCH: build the taken branch's child lazily, jump to its state range.
            if self.sel {
                self.__cT = mk_val(self.dt, 100);
                self.state = 1;
            } else {
                self.__cE = mk_val(self.de, 200);
                self.state = 2;
            }
        }
        if self.state == 1 {                           // then branch
            let r: bool = ValFut.poll(&self.__cT);
            if !r { return false; }
            let a: i32 = ValFut_take_result(&self.__cT);
            self.out = self.base + a;
            self.state = 3;                            // -> continuation
        }
        if self.state == 2 {                           // else branch
            let r: bool = ValFut.poll(&self.__cE);
            if !r { return false; }
            let b: i32 = ValFut_take_result(&self.__cE);
            self.out = self.base + b;
            self.state = 3;                            // -> continuation
        }
        if self.state == 3 {                           // continuation (tail)
            self.result = self.out;
            self.state = 4;
            return true;
        }
        return false;
    }
    fn cancel(self: *mut pick__Fut) -> void { pick__Fut_cancel(self); }   // E1
}
fn pick__Fut_take_result(self: *mut pick__Fut) -> i32 { return self.result; }
// cancel walks the active child for the current state (only one branch child is ever live).
fn pick__Fut_cancel(self: *mut pick__Fut) -> void {
    if self.state == 0 { ValFut_cancel(&self.__c0); }
    if self.state == 1 { ValFut_cancel(&self.__cT); }
    if self.state == 2 { ValFut_cancel(&self.__cE); }
    self.state = 4;
}

export fn async_branch_lowering_run() -> u32 {
    var acc: u32 = 0;

    // (1) THEN branch: sel=true. base=10 (ready@1), a=100 (ready@3) -> out=110, done at tick 3.
    g_clock = 0; g_open = 0;
    var ft: pick__Fut = pick(true, 3, 9);
    let tt: u64 = run_to_completion(&ft, tick_idle);
    if pick__Fut_take_result(&ft) == 110 { acc = acc ^ 0x1; }
    if tt == 3 { acc = acc ^ 0x2; }
    if g_open == 0 { acc = acc ^ 0x4; }          // both consumed (only then child built)

    // (2) ELSE branch: sel=false. base=10 (ready@1), b=200 (ready@5) -> out=210, done at tick 5.
    g_clock = 0; g_open = 0;
    var fe: pick__Fut = pick(false, 9, 5);
    let te: u64 = run_to_completion(&fe, tick_idle);
    if pick__Fut_take_result(&fe) == 210 { acc = acc ^ 0x8; }
    if te == 5 { acc = acc ^ 0x10; }
    if g_open == 0 { acc = acc ^ 0x20; }

    // (3) cancel mid-branch: start the THEN path, advance past the pre-await so it is parked on the
    // then child (one slot held), cancel, prove the slot is reclaimed and poll is idempotent.
    g_clock = 0; g_open = 0;
    var fc: pick__Fut = pick(true, 100, 9);      // then child ready@100 (won't, in this window)
    let c0: bool = pick__Fut.poll(&fc);          // clock 0: pre-await pending. g_open=1
    tick_idle();                                 // clock 1
    let c1: bool = pick__Fut.poll(&fc);          // pre ready -> release; dispatch then -> build &
                                                 // poll then child -> pending. g_open=1
    if !c0 && !c1 { acc = acc ^ 0x40; }
    if g_open == 1 { acc = acc ^ 0x80; }         // one slot held (the then child)
    pick__Fut_cancel(&fc);                       // walk the active then child -> release its slot
    if g_open == 0 { acc = acc ^ 0x100; }
    let c2: bool = pick__Fut.poll(&fc);          // canceled -> DONE: poll true, no churn
    if c2 && g_open == 0 { acc = acc ^ 0x200; }

    if acc != 0x3FF { return 0; }
    return 1;
}
