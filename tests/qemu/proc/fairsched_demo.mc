// Fair-share scheduling (kernel/core/proc_sched): proc_pick_fair selects the *least-served*
// runnable slot (fewest ticks consumed) so no agent monopolizes the CPU, and proc_throttle
// deprioritizes a misbehaving agent — pushing it to the back of the fair queue — without
// killing it. Pausing a slot makes it non-runnable and excludes it from the pick.
import "kernel/core/process.mc";

global g_t: ProcTable;
fn worker() -> void {}

export fn fairsched_run() -> u32 {
    var pass: u32 = 1;
    proc_table_init(&g_t);

    // Three runnable children: slots 1, 2, 3 (bootstrap is slot 0).
    let a: u32 = proc_spawn(&g_t, 0x1000, worker);
    let b: u32 = proc_spawn(&g_t, 0x2000, worker);
    let c: u32 = proc_spawn(&g_t, 0x3000, worker);
    if a != 1 { pass = 0; }
    if b != 2 { pass = 0; }
    if c != 3 { pass = 0; }

    // Differentiate how much each has been served. Pause slot 0 so the bootstrap (0 ticks)
    // does not dominate the fair pick — it is non-runnable and must be excluded.
    proc_pause(&g_t, 0);
    if proc_is_runnable_slot(&g_t, 0) { pass = 0; } // paused -> not runnable

    // a served most, c served least: c is the fair (least-served) pick.
    g_t.procs[1].ticks = 30;
    g_t.procs[2].ticks = 20;
    g_t.procs[3].ticks = 10;

    switch proc_pick_fair(&g_t) {
        ok(s) => { if s != 3 { pass = 0; } } // slot 3 = fewest ticks
        err(e) => { pass = 0; }
    }

    // Throttle the least-served slot heavily: its effective cost now exceeds the others, so the
    // fair pick moves to the next least-served runnable slot (slot 2 at 20 ticks).
    proc_throttle(&g_t, 3, 1000);
    switch proc_pick_fair(&g_t) {
        ok(s) => { if s != 2 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    // Throttled agent stays alive and runnable — deprioritized, not killed.
    if !proc_is_runnable_slot(&g_t, 3) { pass = 0; }

    // Clearing the throttle restores the original least-served-first pick (slot 3).
    proc_throttle_clear(&g_t, 3);
    switch proc_pick_fair(&g_t) {
        ok(s) => { if s != 3 { pass = 0; } }
        err(e) => { pass = 0; }
    }

    // Pausing the current fair pick (slot 3) excludes it; the pick falls to slot 2.
    proc_pause(&g_t, 3);
    switch proc_pick_fair(&g_t) {
        ok(s) => { if s != 2 { pass = 0; } }
        err(e) => { pass = 0; }
    }

    // Tie-break: equal effective ticks -> lower slot index wins. Resume slots, equalize.
    proc_resume(&g_t, 3);
    g_t.procs[1].ticks = 5;
    g_t.procs[2].ticks = 5;
    g_t.procs[3].ticks = 5;
    switch proc_pick_fair(&g_t) {
        ok(s) => { if s != 1 { pass = 0; } } // lowest runnable slot on a tie
        err(e) => { pass = 0; }
    }

    // No runnable slot -> NoRunnable. Pause all three children.
    proc_pause(&g_t, 1);
    proc_pause(&g_t, 2);
    proc_pause(&g_t, 3);
    switch proc_pick_fair(&g_t) {
        ok(s) => { pass = 0; }
        err(e) => {} // expected: NoRunnable
    }

    return pass;
}
