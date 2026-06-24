// Phase D, build-order step 2: the EXACT MC a future `async fn` -> stackless-state-machine
// transform should GENERATE, written by hand as the acceptance target. It pins the typed-result
// ABI (`poll() -> bool` + a once-only `take_result() -> T`) and the stackless-poll invariant
// (a generated poll only polls child futures and returns pending — it never blocks). Driving
// these through the Phase-A executor (`run_to_completion`) and diffing C vs LLVM proves the ABI
// lowers identically on both backends. When the transform lands, its output must match fixtures
// of this shape. (No parser sugar exists yet; this is all ordinary MC.)

import "std/task.mc";

global g_clock: u64 = 0;
fn tick_idle() -> void { g_clock = g_clock + 1; }

// ---- leaf: a mock async value, ready at `deadline`, yielding `val`. The poll/take_result
// shape a broker *readiness* future would expose (the value lives in the concrete future). ----
struct ValFuture { deadline: u64, val: i32 }
fn valfuture_init(f: *mut ValFuture, deadline: u64, val: i32) -> void {
    f.deadline = deadline;
    f.val = val;
}
impl Future for ValFuture {
    fn poll(self: *mut ValFuture) -> bool { return g_clock >= self.deadline; }
    fn cancel(self: *mut ValFuture) -> void { self.val = 0; }   // E1: leaf has no slot; clear on drop
}
fn valfuture_take_result(f: *mut ValFuture) -> i32 { return f.val; } // valid once, after poll()==true

// ---- generated for `async fn fetch(d, v) -> i32 { return await mk(d, v); }` ----
struct FetchFuture { state: u8, child: ValFuture, result: i32 }
fn fetch_init(f: *mut FetchFuture, d: u64, v: i32) -> void {
    f.state = 0;
    valfuture_init(&f.child, d, v);
    f.result = 0;
}
impl Future for FetchFuture {
    fn poll(self: *mut FetchFuture) -> bool {
        if self.state == 0 {
            let r: bool = ValFuture.poll(&self.child);           // `await mk`: poll the child future
            if !r { return false; }                    // pending -> suspend (return up the chain)
            self.result = valfuture_take_result(&self.child); // ready -> take its typed value
            self.state = 1;
        }
        return true;
    }
    // E1: walk the active child (state 0 holds the live `child`), then mark done (state 1).
    fn cancel(self: *mut FetchFuture) -> void {
        if self.state == 0 { ValFuture.cancel(&self.child); }
        self.state = 1;
    }
}
fn fetch_take_result(f: *mut FetchFuture) -> i32 { return f.result; }

// ---- generated for `async fn sum_two(da,va, db,vb) -> i32 {
//        let a = await fetch(da,va); let b = await fetch(db,vb); return a + b; }` ----
// Two awaits in sequence; `a` is a live local across the second await -> a STATE FIELD.
struct SumFuture { state: u8, fa: FetchFuture, fb: FetchFuture, a: i32, result: i32 }
fn sum_init(f: *mut SumFuture, da: u64, va: i32, db: u64, vb: i32) -> void {
    f.state = 0;
    fetch_init(&f.fa, da, va);
    fetch_init(&f.fb, db, vb);
    f.a = 0;
    f.result = 0;
}
impl Future for SumFuture {
    fn poll(self: *mut SumFuture) -> bool {
        if self.state == 0 {                           // await fetch(a)
            let r: bool = FetchFuture.poll(&self.fa);
            if !r { return false; }
            self.a = fetch_take_result(&self.fa);      // captured across the next await
            self.state = 1;
        }
        if self.state == 1 {                           // await fetch(b)
            let r: bool = FetchFuture.poll(&self.fb);
            if !r { return false; }
            let b: i32 = fetch_take_result(&self.fb);
            self.result = self.a + b;
            self.state = 2;
        }
        return true;
    }
    // E1: at most one child is live at a time — state 0 holds `fa`, state 1 holds `fb`.
    fn cancel(self: *mut SumFuture) -> void {
        if self.state == 0 { FetchFuture.cancel(&self.fa); }
        if self.state == 1 { FetchFuture.cancel(&self.fb); }
        self.state = 2;
    }
}
fn sum_take_result(f: *mut SumFuture) -> i32 { return f.result; }

export fn async_lowering_run() -> u32 {
    var acc: u32 = 0;

    // single await + scalar result: ready at tick 3, value 22
    g_clock = 0;
    var ff: FetchFuture = uninit; fetch_init(&ff, 3, 22);
    run_to_completion(&ff, tick_idle);
    if fetch_take_result(&ff) == 22 { acc = acc ^ 0x1; }

    // two awaits in sequence: a (=10) ready at 3, b (=32) ready at 5 -> 42, completing at tick 5
    g_clock = 0;
    var sf: SumFuture = uninit; sum_init(&sf, 3, 10, 5, 32);
    let ticks: u64 = run_to_completion(&sf, tick_idle);
    if sum_take_result(&sf) == 42 { acc = acc ^ 0x2; }
    if ticks == 5 { acc = acc ^ 0x4; }   // completes only when the LATER await is ready

    // entry-mode contract: 1 = pass, 0 = fail.
    if acc != 0x7 { return 0; }
    return 1;
}
