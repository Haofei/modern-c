// MINIX-style process hardening: generation-checked endpoints (stale refs fail closed),
// derived runnable state (block reasons), and a central death-cleanup path (waiters on a
// dead process are released with a DEAD message, not left blocked forever).
import "kernel/core/process.mc";
import "kernel/core/ipc.mc";

global g_t: ProcTable;
fn worker() -> void {}

// A counting idle hook: stands in for the platform `wfi`, so the test can observe that the
// idle path is taken (instead of a busy spin) when a blocked process has nothing else to run.
struct IdleCounter { n: u32 }
global g_idle_counter: IdleCounter;
fn count_idle(c: *mut IdleCounter) -> void {
    c.n = c.n + 1;
}

export fn endpoint_run() -> u32 {
    var pass: u32 = 1;
    let tbl: *mut ProcTable = &g_t;
    proc_table_init(&g_t);

    // ---- #3 endpoints: generation invalidates a reused slot ----
    let a: u32 = proc_spawn(&g_t, 0x1000, worker); // slot 1, gen 1
    if a != 1 { pass = 0; }
    let ep_a: Endpoint = proc_endpoint(&g_t, a);
    if !endpoint_live(&g_t, ep_a) { pass = 0; }

    // make 'a' a zombie child of the bootstrap and reap it -> slot 1 becomes Unused
    let pa: *mut Process = &tbl.procs[1];
    pa.state = .Zombie;
    pa.parent = 0;
    switch proc_reap(&g_t, 0) {
        ok(info) => { if info.pid != 1 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    if endpoint_live(&g_t, ep_a) { pass = 0; } // freed slot -> stale endpoint

    // respawn reuses slot 1 with a bumped generation
    let b: u32 = proc_spawn(&g_t, 0x2000, worker);
    if b != 1 { pass = 0; }                    // same slot reused
    if endpoint_live(&g_t, ep_a) { pass = 0; } // old endpoint STILL stale (gen mismatch)
    let ep_b: Endpoint = proc_endpoint(&g_t, b);
    if !endpoint_live(&g_t, ep_b) { pass = 0; }
    if ep_b.gen == ep_a.gen { pass = 0; }      // a new incarnation has a new generation

    // Parent identity is generation-checked too: a child of an old slot-1
    // incarnation must not be reaped by a later unrelated process that reuses pid 1.
    g_t.current = 1;
    let child: u32 = proc_spawn(&g_t, 0x3000, worker);
    if child != 2 { pass = 0; }
    g_t.current = 0;
    let p_child: *mut Process = &tbl.procs[2];
    p_child.state = .Zombie;
    let old_parent: *mut Process = &tbl.procs[1];
    old_parent.state = .Zombie;
    switch proc_reap(&g_t, 0) {
        ok(info2) => { if info2.pid != 1 { pass = 0; } }
        err(e2) => { pass = 0; }
    }
    let reused_parent_pid: u32 = proc_spawn(&g_t, 0x4000, worker);
    if reused_parent_pid != 1 { pass = 0; }
    switch proc_reap(&g_t, reused_parent_pid) {
        ok(info3) => { pass = 0; }
        err(e3) => {}
    }
    p_child.state = .Unused;

    // a fabricated endpoint to a never-used slot validates as DeadEndpoint
    let bogus: Endpoint = .{ .slot = 1, .gen = 999 };
    switch endpoint_slot(&g_t, bogus) {
        ok(s) => { pass = 0; }
        err(e) => {}
    }

    // ---- #1 derived runnable: a blocked process is not pickable ----
    proc_block(&g_t, 1, BLOCK_RECV);
    if proc_state_code(&g_t, 1) != 3 { pass = 0; } // Blocked (derived)
    proc_unblock(&g_t, 1, BLOCK_RECV);
    if proc_state_code(&g_t, 1) != 1 { pass = 0; } // Ready again

    // ---- #2 schedctl: scheduling policy set via one path; quantum accounting ----
    proc_schedctl(&g_t, 1, 7, 3, 4); // priority 7, quantum 3, scheduler endpoint 4
    if proc_quantum(&g_t, 1) != 3 { pass = 0; }
    if proc_sched_endpoint(&g_t, 1) != 4 { pass = 0; }
    // tick the current process (bootstrap, default quantum 10) until its quantum expires
    var k: u32 = 0;
    var expired: bool = false;
    while k < 10 {
        expired = proc_tick(&g_t);
        k = k + 1;
    }
    if !expired { pass = 0; }                   // quantum expired on the 10th tick
    if proc_ticks(&g_t, 0) != 10 { pass = 0; }  // accounting recorded
    if proc_quantum(&g_t, 0) != 0 { pass = 0; }
    // edge-triggered: ticking an already-expired quantum does NOT re-fire the notification
    if proc_tick(&g_t) { pass = 0; }

    // ---- #4 death cleanup: a waiter on a dying process is released with DEAD ----
    // slot 1 is blocked receiving-from the bootstrap (slot 0); record that wait.
    let p1: *mut Process = &tbl.procs[1];
    let boot_ep: Endpoint = proc_endpoint(&g_t, 0);
    p1.wait_slot = 0;
    p1.wait_gen = boot_ep.gen;
    proc_block(&g_t, 1, BLOCK_RECV);
    if proc_state_code(&g_t, 1) != 3 { pass = 0; } // blocked, waiting on bootstrap

    // the bootstrap (current) exits -> death cleanup unblocks slot 1 + clears its wait
    proc_exit(&g_t, 7);
    // proc_exit switched to slot 1 (now the only runnable process), unblocked
    if proc_state_code(&g_t, 1) != 2 { pass = 0; } // unblocked + running
    if endpoint_live(&g_t, boot_ep) { pass = 0; }  // the bootstrap's endpoint is now dead

    // a receive_from the dead bootstrap returns DEAD out-of-band (guaranteed, not via mailbox)
    var msg: Message = message_zero();
    ipc_receive_from(&g_t, 0, &msg);
    if msg.tag != ipc_tag_dead() { pass = 0; }
    if msg.from != 0 { pass = 0; }                 // from the now-dead bootstrap (pid 0)

    // ---- send/notify to a dead destination is rejected, never spins ----
    if ipc_notify(&g_t, 0, 1) { pass = 0; }        // bootstrap is a zombie -> notify rejected
    switch ipc_notify_ep(&g_t, boot_ep, 1) {       // stale endpoint -> DeadEndpoint
        ok(nok) => { pass = 0; }
        err(nerr) => {}
    }
    switch ipc_send_ep(&g_t, boot_ep, 1, 0, 0, 0) { // stale endpoint -> DeadEndpoint
        ok(sok) => { pass = 0; }
        err(serr) => {}
    }
    switch ipc_call_ep(&g_t, boot_ep, 1, 0, 0, 0, &msg) { // stale endpoint -> DeadEndpoint
        ok(cok) => { pass = 0; }
        err(cerr) => {}
    }
    ipc_send(&g_t, 0, 1, 0, 0, 0); // dead dst -> returns immediately; reaching the next line proves no spin

    // ---- #2 idle: with nothing else runnable, the blocking yield runs the idle hook ----
    // (rather than returning to busy-spin as a blocked current process). current is slot 1;
    // the bootstrap is a zombie and no other slot is runnable, so yield_or_idle must idle.
    g_idle_counter.n = 0;
    proc_set_idle(&g_t, bind(&g_idle_counter, count_idle));
    proc_yield_or_idle(&g_t);
    if g_idle_counter.n != 1 { pass = 0; }         // idled once instead of spinning
    proc_yield_or_idle(&g_t);
    if g_idle_counter.n != 2 { pass = 0; }
    return pass;
}
