// Phase D, build-order steps 6 + (the lazy-construction half of) 3: the EXACT MC a future
// `async fn` -> stackless state-machine transform should GENERATE once it does
//   (a) LAZY per-state child construction — a later `await`'s call may reference an EARLIER
//       `await`'s result (e.g. `let t = await login(); let d = await fetch(t);`), so the child
//       future for state N is built at the TRANSITION into state N (when `t` exists), not all
//       up front in the constructor; and
//   (b) CANCELLATION / drop — a generated `cancel` that walks the currently-active child future
//       down to the in-flight leaf and RELEASES its broker slot, so dropping a still-pending
//       future does not LEAK the slot (kernel/lib/async.mc `async_cancel`).
//
// Hand-written as the acceptance target (ordinary MC; no parser sugar). Driving it through the
// Phase-A executor and diffing C vs LLVM proves the lazy + cancel ABI lowers identically on both
// backends. When the transform grows these features its output must match fixtures of this shape.
//
// KEY definite-init fact this relies on: only SCALAR `uninit` vars are def-init-tracked (sema),
// so a constructor that leaves the LATER child-future fields (`__c1`) unwritten — to build them
// lazily in `poll` — is accepted; the field is written before its first poll.

import "std/task.mc";

global g_clock: u64 = 0;
fn tick_idle() -> void { g_clock = g_clock + 1; }

// ---- a cancellable mock leaf modeling "a request that holds one inflight broker slot". The real
// leaf is std/task.mc's SlotFuture over kernel async_submit / async_cancel; here a global counts
// live slots so a LEAK (cancel not walked to the leaf) or a DOUBLE-free is observable on BOTH
// backends. `held` makes release idempotent: a slot is freed exactly once, by completion OR drop. ----
global g_inflight: i32 = 0;       // live broker slots; must return to 0
fn slot_acquire() -> void { g_inflight = g_inflight + 1; }
fn slot_release() -> void { g_inflight = g_inflight - 1; }

struct SlotLeaf { ready_at: u64, val: i32, held: bool }
// the awaited leaf call `await mk(ready_at, val)`: acquires a slot.
fn mk(ready_at: u64, val: i32) -> SlotLeaf {
    var f: SlotLeaf = uninit;
    f.ready_at = ready_at;
    f.val = val;
    f.held = true;
    slot_acquire();
    return f;
}
impl Future for SlotLeaf {
    fn poll(self: *mut SlotLeaf) -> bool {
        if g_clock >= self.ready_at {
            if self.held { self.held = false; slot_release(); }   // completion consumes the slot
            return true;
        }
        return false;
    }
}
fn slotleaf_take_result(f: *mut SlotLeaf) -> i32 { return f.val; }
fn slotleaf_cancel(f: *mut SlotLeaf) -> void { if f.held { f.held = false; slot_release(); } } // drop releases

// ---- generated for `async fn login(dl) -> i32 { let t = await mk(dl, 77); return t; }` ----
// Single await of a leaf; child built eagerly in the constructor (no prior-await dependency).
struct login__Fut { state: u8, __c0: SlotLeaf, dl: u64, result: i32 }
fn login(dl: u64) -> login__Fut {
    var self: login__Fut = uninit;
    self.state = 0;
    self.dl = dl;
    self.__c0 = mk(self.dl, 77);
    self.result = 0;
    return self;
}
impl Future for login__Fut {
    fn poll(self: *mut login__Fut) -> bool {
        if self.state == 1 { return true; }            // DONE (idempotent)
        if self.state == 0 {
            let r: bool = SlotLeaf.poll(&self.__c0);
            if !r { return false; }
            self.result = slotleaf_take_result(&self.__c0);
            self.state = 1;
        }
        return true;
    }
}
fn login__Fut_take_result(self: *mut login__Fut) -> i32 { return self.result; }
fn login__Fut_cancel(self: *mut login__Fut) -> void {
    if self.state == 0 { slotleaf_cancel(&self.__c0); }   // leaf still in flight -> release its slot
    self.state = 1;                                        // mark DONE: cancel is idempotent
}

// ---- generated for `async fn fetch(token, df) -> i32 { let d = await mk(df, token + 1000); return d; }` ----
// Single await; the awaited call uses `token`, but token is a PARAM (captured), so no LAZY
// dependency — child0 is built eagerly in the constructor from the captured param fields.
struct fetch__Fut { state: u8, __c0: SlotLeaf, token: i32, df: u64, result: i32 }
fn fetch(token: i32, df: u64) -> fetch__Fut {
    var self: fetch__Fut = uninit;
    self.state = 0;
    self.token = token;
    self.df = df;
    self.__c0 = mk(self.df, self.token + 1000);
    self.result = 0;
    return self;
}
impl Future for fetch__Fut {
    fn poll(self: *mut fetch__Fut) -> bool {
        if self.state == 1 { return true; }
        if self.state == 0 {
            let r: bool = SlotLeaf.poll(&self.__c0);
            if !r { return false; }
            self.result = slotleaf_take_result(&self.__c0);
            self.state = 1;
        }
        return true;
    }
}
fn fetch__Fut_take_result(self: *mut fetch__Fut) -> i32 { return self.result; }
fn fetch__Fut_cancel(self: *mut fetch__Fut) -> void {
    if self.state == 0 { slotleaf_cancel(&self.__c0); }
    self.state = 1;
}

// ---- generated for `async fn flow(dl, df) -> i32 {
//        let token = await login(dl);
//        let data  = await fetch(token, df);   // <-- DEPENDS on the prior await result `token`
//        return data; }` ----
// The SECOND await's call references `token`, a result that does not exist until the FIRST await
// completes — so `__c1` is built LAZILY at the 0->1 transition, NOT in the constructor.
struct flow__Fut { state: u8, __c0: login__Fut, __c1: fetch__Fut, dl: u64, df: u64, token: i32, result: i32 }
fn flow(dl: u64, df: u64) -> flow__Fut {
    var self: flow__Fut = uninit;
    self.state = 0;
    self.dl = dl;
    self.df = df;
    self.__c0 = login(self.dl);   // child0 built eagerly (no dependency)
    self.token = 0;
    self.result = 0;
    // __c1 is intentionally NOT built here — it needs `token`. Built at the 0->1 transition.
    return self;
}
impl Future for flow__Fut {
    fn poll(self: *mut flow__Fut) -> bool {
        if self.state == 2 { return true; }            // DONE
        if self.state == 0 {
            let r0: bool = login__Fut.poll(&self.__c0);
            if !r0 { return false; }
            self.token = login__Fut_take_result(&self.__c0);
            self.__c1 = fetch(self.token, self.df);    // LAZY: build child1 now, using `token`
            self.state = 1;
        }
        if self.state == 1 {
            let r1: bool = fetch__Fut.poll(&self.__c1);
            if !r1 { return false; }
            self.result = fetch__Fut_take_result(&self.__c1);
            self.state = 2;
        }
        return true;
    }
}
fn flow__Fut_take_result(self: *mut flow__Fut) -> i32 { return self.result; }
// cancel walks ONLY the currently-active child (the one for the current state). With lazy
// construction at most one child exists at a time: at state 0 it is __c0 (login); at state 1 it
// is __c1 (fetch, lazily built at the transition). States >= tail (2) hold no active child.
fn flow__Fut_cancel(self: *mut flow__Fut) -> void {
    if self.state == 0 { login__Fut_cancel(&self.__c0); }
    if self.state == 1 { fetch__Fut_cancel(&self.__c1); }
    self.state = 2;   // mark DONE: subsequent poll/cancel are no-ops (no double-free)
}

export fn async_cancel_lowering_run() -> u32 {
    var acc: u32 = 0;

    // ---- (1) happy path with a DEPENDENT await: login -> token(=77) -> fetch(token) -> 1077.
    g_clock = 0; g_inflight = 0;
    var f1: flow__Fut = flow(2, 4);                 // login leaf ready@2; fetch leaf ready@4
    let ticks: u64 = run_to_completion(&f1, tick_idle);
    if flow__Fut_take_result(&f1) == 1077 { acc = acc ^ 0x1; }  // fetch saw token 77 -> 1077 (lazy worked)
    if ticks == 4 { acc = acc ^ 0x2; }              // completes only when the LATER leaf is ready
    if g_inflight == 0 { acc = acc ^ 0x4; }         // both slots consumed on completion (no leak)

    // ---- (2) cancel a still-pending future RECLAIMS its slot (no leak on drop).
    g_clock = 0; g_inflight = 0;
    var f2: flow__Fut = flow(1, 100);               // login ready@1; fetch leaf ready@100 (won't, here)
    let p0: bool = flow__Fut.poll(&f2);             // clock 0: login pending. g_inflight=1 (login leaf)
    tick_idle();                                    // clock 1
    let p1: bool = flow__Fut.poll(&f2);             // clock 1: login ready -> release; build fetch leaf
                                                    //          -> acquire; fetch pending. g_inflight=1
    if !p0 && !p1 { acc = acc ^ 0x8; }              // pending on both polls (not yet complete)
    if g_inflight == 1 { acc = acc ^ 0x40; }        // exactly one slot held (fetch); login's was consumed
    flow__Fut_cancel(&f2);                          // walk the active child (fetch) -> release its slot
    if g_inflight == 0 { acc = acc ^ 0x10; }        // cancel reclaimed the would-be-leaked slot
    let p2: bool = flow__Fut.poll(&f2);             // a canceled future is DONE: poll true, no slot churn
    if p2 && g_inflight == 0 { acc = acc ^ 0x20; }  // idempotent: cancel set DONE, no double-free

    // entry-mode contract: 1 = pass, 0 = fail.
    if acc != 0x7F { return 0; }
    return 1;
}
