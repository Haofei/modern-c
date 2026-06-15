// Host test for ipc_send_result: a bounded blocking send with a TYPED outcome that
// distinguishes the failure modes the bool variants conflate — Denied (allow_mask), DeadTarget
// (no such/exited process), and Timeout (mailbox stayed full). Single-threaded: proc_yield does
// not run the destination here, so a full mailbox stays full for the whole budget.
import "kernel/core/process.mc";

global g_t: ProcTable;
fn worker() -> void {}

// 0 = delivered, 1 = Denied, 2 = DeadTarget, 3 = Timeout.
fn send_outcome(dst: u32, budget: u32) -> u32 {
    var code: u32 = 0;
    switch ipc_send_result(&g_t, dst, 100, 0, 0, 0, budget) {
        ok(d) => {
            code = 0;
        }
        err(e) => {
            switch e {
                .Denied => { code = 1; }
                .DeadTarget => { code = 2; }
                .Timeout => { code = 3; }
            }
        }
    }
    return code;
}

export fn ipc_result_run() -> u32 {
    var pass: u32 = 1;
    proc_table_init(&g_t);
    let p: u32 = proc_spawn(&g_t, 0x1000, worker); // pid/slot 1

    // delivered: bootstrap permits all, destination live, mailbox has room
    if send_outcome(p, 0) != 0 { pass = 0; }

    // DeadTarget: a pid that was never spawned
    if send_outcome(7, 0) != 2 { pass = 0; }

    // Timeout: fill the destination's mailbox (depth IPC_SLOTS = 4; one slot already used above),
    // then a budget-0 send finds it full.
    var k: u32 = 0;
    while k < 4 {
        let sent: bool = ipc_send_try(&g_t, p, 100, 0, 0, 0);
        k = k + 1;
    }
    if send_outcome(p, 0) != 3 { pass = 0; }

    // Denied: revoke the bootstrap's permission to send to the destination
    proc_set_allow_mask(&g_t, 0, 0);
    if send_outcome(p, 0) != 1 { pass = 0; }

    return pass;
}
