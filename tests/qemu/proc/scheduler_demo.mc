// Scheduler service: the kernel owns the mechanism (quantum accounting + the expiry edge); on
// expiry it notifies the process's scheduler service (TAG_QUANTUM, from = the expired task), and
// the service applies policy (refresh quantum / priority). Policy lives outside the kernel.
import "kernel/core/process.mc";
import "kernel/core/ipc.mc";

global g_t: ProcTable;
fn worker() -> void {}

export fn scheduler_run() -> u32 {
    var pass: u32 = 1;
    proc_table_init(&g_t);
    let svc: u32 = proc_spawn(&g_t, 0x1000, worker); // pid 1 = the scheduler service
    if svc != 1 { pass = 0; }

    // bootstrap (0) is a task scheduled by service 1, with a quantum of 3 ticks
    proc_schedctl(&g_t, 0, 5, 3, 1);
    if proc_quantum(&g_t, 0) != 3 { pass = 0; }
    if proc_sched_endpoint(&g_t, 0) != 1 { pass = 0; }

    // ----- timer-driven preemption decision layer -----
    // proc_preempt_tick is the irq-safe timer hook: account a tick and raise need_resched on the
    // quantum-expiry edge. proc_preempt_pending reads the flag; proc_preempt_clear clears it. (The
    // switch itself happens later at a safe preemption point via proc_preempt_point -> the gated
    // proc_yield_priority.) This consumes the quantum, so we refresh it for the notify flow below.
    if proc_preempt_pending() { pass = 0; }     // nothing requested yet
    if proc_preempt_tick(&g_t) { pass = 0; }    // tick 1: quantum 3 -> 2, no expiry
    if proc_preempt_tick(&g_t) { pass = 0; }    // tick 2: 2 -> 1, no expiry
    if proc_preempt_pending() { pass = 0; }     // still not expired -> no reschedule requested
    if !proc_preempt_tick(&g_t) { pass = 0; }   // tick 3: 1 -> 0, expiry edge
    if !proc_preempt_pending() { pass = 0; }    // need_resched now raised
    proc_preempt_clear();
    if proc_preempt_pending() { pass = 0; }     // cleared without switching
    proc_refresh_quantum(&g_t, 0, 3);           // restore the quantum for the notify flow below

    // ticks 1,2 don't expire -> no notification
    if proc_tick_notify(&g_t) { pass = 0; }
    if proc_tick_notify(&g_t) { pass = 0; }
    if proc_inbox_count(&g_t, 1) != 0 { pass = 0; }
    // tick 3 hits the expiry edge -> notify the scheduler service
    if !proc_tick_notify(&g_t) { pass = 0; }
    if proc_inbox_count(&g_t, 1) != 1 { pass = 0; }
    // edge-triggered: further ticks on the exhausted quantum do not re-notify
    if proc_tick_notify(&g_t) { pass = 0; }
    if proc_inbox_count(&g_t, 1) != 1 { pass = 0; }

    // the scheduler service receives the expiry notification (from = the expired task)
    proc_block(&g_t, 0, BLOCK_RECV); // park the task so the yield switches to the service
    proc_yield(&g_t);                // current -> pid 1 (the scheduler service)
    var msg: Message = message_zero();
    ipc_receive(&g_t, &msg);
    if msg.from != 0 { pass = 0; }
    if msg.tag != ipc_tag_quantum() { pass = 0; }

    // the service applies policy: refresh the task's quantum
    proc_refresh_quantum(&g_t, 0, 10);
    if proc_quantum(&g_t, 0) != 10 { pass = 0; }

    // ----- supervision: heartbeat liveness -----
    // Enroll slot 0 (beat at least every 10 ticks, from t=100); detect a missed heartbeat, recover
    // on a fresh beat, and stop flagging once unsupervised.
    proc_supervise(&g_t, 0, 100, 10);
    if proc_liveness_expired(&g_t, 0, 105) { pass = 0; }   // 5 ticks since beat: alive
    if proc_liveness_expired(&g_t, 0, 110) { pass = 0; }   // exactly 10: still within deadline
    if !proc_liveness_expired(&g_t, 0, 111) { pass = 0; }  // 11 > 10: missed -> expired
    proc_heartbeat(&g_t, 0, 111);                          // agent beats again at 111
    if proc_liveness_expired(&g_t, 0, 120) { pass = 0; }   // 9 since the new beat: alive
    proc_unsupervise(&g_t, 0);
    if proc_liveness_expired(&g_t, 0, 1000) { pass = 0; }  // unsupervised -> never expired

    // ----- supervision: restart / crash-loop policy (budget = 3 restarts) -----
    if !proc_restart_allowed(&g_t, 0, 3) { pass = 0; }     // 0 restarts so far: allowed
    if proc_restart_record(&g_t, 0) != 1 { pass = 0; }     // restart #1
    if proc_restart_record(&g_t, 0) != 2 { pass = 0; }     // restart #2
    if !proc_restart_allowed(&g_t, 0, 3) { pass = 0; }     // 2 < 3: still allowed
    if proc_restart_record(&g_t, 0) != 3 { pass = 0; }     // restart #3
    if proc_restart_allowed(&g_t, 0, 3) { pass = 0; }      // 3 >= 3: crash-looping -> give up
    proc_restart_reset(&g_t, 0);                           // a clean run clears the counter
    if !proc_restart_allowed(&g_t, 0, 3) { pass = 0; }     // allowed again after reset

    // ----- supervisor loop verdict (proc_supervise_step: liveness + restart budget combined) -----
    proc_restart_reset(&g_t, 0);
    proc_supervise(&g_t, 0, 200, 10);                      // re-enroll: beat every <=10 ticks from t=200
    switch proc_supervise_step(&g_t, 0, 205, 3) {          // alive (5 ticks) -> None
        .None => {} _ => { pass = 0; }
    }
    switch proc_supervise_step(&g_t, 0, 220, 3) {          // missed (20>10), within budget -> Restart
        .Restart => {} _ => { pass = 0; }
    }
    proc_restart_record(&g_t, 0);                          // the supervisor exhausts the budget...
    proc_restart_record(&g_t, 0);
    proc_restart_record(&g_t, 0);                          // count == 3
    switch proc_supervise_step(&g_t, 0, 240, 3) {          // missed AND out of budget -> GiveUp (crash loop)
        .GiveUp => {} _ => { pass = 0; }
    }
    return pass;
}
