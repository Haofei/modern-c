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
    return pass;
}
