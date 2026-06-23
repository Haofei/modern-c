// Differential smoke test for the pure async task vocabulary (std/task.mc, Phase A):
// SlotFuture (an id mapped to a pending future via an injected completion source), the
// join2 / race2 / timeout combinators, and the executor (run_to_completion).
// A mock completion source `done_at(id)` reports a request "done" once a virtual clock
// reaches `id`; the executor's idle hook advances that clock — so each future completes at
// a deterministic tick. Entry mode diffs C vs LLVM, so any backend disagreement on `*dyn`
// dispatch, the combinators, or the executor fails.

import "std/task.mc";

global g_clock: u64 = 0;

fn tick_idle() -> void { g_clock = g_clock + 1; }
fn done_at(id: u64) -> bool { return g_clock >= id; }

export fn task_run() -> u32 {
    var acc: u32 = 0;

    // join2: deadlines 3 and 5 -> both complete at tick 5
    g_clock = 0;
    var s1: SlotFuture = uninit; slot_future_init(&s1, 3, done_at);
    var s2: SlotFuture = uninit; slot_future_init(&s2, 5, done_at);
    var j: Join2 = uninit; join2_init(&j, &s1, &s2);
    if run_to_completion(&j, tick_idle) == 5 { acc = acc ^ 0x01; }

    // race2: deadlines 7 and 2 -> b wins at tick 2
    g_clock = 0;
    var r1: SlotFuture = uninit; slot_future_init(&r1, 7, done_at);
    var r2: SlotFuture = uninit; slot_future_init(&r2, 2, done_at);
    var rc: Race2 = uninit; race2_init(&rc, &r1, &r2);
    if run_to_completion(&rc, tick_idle) == 2 { acc = acc ^ 0x02; }
    if race2_winner(&rc) == 1 { acc = acc ^ 0x04; }

    // timeout that FIRES: inner deadline 100, budget 4 ticks
    g_clock = 0;
    var slow: SlotFuture = uninit; slot_future_init(&slow, 100, done_at);
    var to: Timeout = uninit; timeout_init(&to, &slow, 4);
    run_to_completion(&to, tick_idle);
    if timeout_timed_out(&to) { acc = acc ^ 0x08; }

    // timeout that does NOT fire: inner deadline 2, budget 10
    g_clock = 0;
    var fast: SlotFuture = uninit; slot_future_init(&fast, 2, done_at);
    var to2: Timeout = uninit; timeout_init(&to2, &fast, 10);
    run_to_completion(&to2, tick_idle);
    if !timeout_timed_out(&to2) { acc = acc ^ 0x10; }

    // nested combinator: join2 of (a slot) and (a timeout wrapping another slot) — proves
    // the combinators compose as Futures over *mut dyn Future
    g_clock = 0;
    var n1: SlotFuture = uninit; slot_future_init(&n1, 4, done_at);
    var n2: SlotFuture = uninit; slot_future_init(&n2, 6, done_at);
    var nto: Timeout = uninit; timeout_init(&nto, &n2, 100);   // generous budget, won't fire
    var nj: Join2 = uninit; join2_init(&nj, &n1, &nto);
    if run_to_completion(&nj, tick_idle) == 6 { acc = acc ^ 0x20; }

    // 0x3F = all six combinator/executor checks passed. Entry-mode contract: 1 = pass, 0 = fail.
    if acc != 0x3F { return 0; }
    return 1;
}
