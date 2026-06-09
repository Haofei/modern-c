// Least privilege: a process is restricted to a set of IPC peers and kernel calls.
// ipc_try_send to a forbidden peer is rejected; a kernel call outside the kcall mask
// is Denied. This is MINIX's per-server privilege model, enforced at the kernel gate.

import "kernel/core/process.mc";
import "kernel/arch/riscv64/idle.mc";
import "kernel/core/ipc.mc";

global g_procs: ProcTable;
fn worker() -> void {}

export fn privilege_demo() -> u32 {
    proc_table_init(&g_procs);
    install_idle(&g_procs); // wfi when nothing runnable
    var pass: u32 = 1;
    let me: u32 = proc_pid(&g_procs); // pid 0 (bootstrap)

    // spawn the peers so the test exercises the privilege gate, not liveness: both pid 1 and
    // pid 2 are live, so a rejected send can only be the allow-mask doing its job.
    if proc_spawn(&g_procs, 0x1000, worker) != 1 { pass = 0; } // pid 1 (a permitted peer)
    if proc_spawn(&g_procs, 0x2000, worker) != 2 { pass = 0; } // pid 2 (a forbidden peer)

    // restrict: may send only to pid 1; may invoke only kernel call op 0
    proc_set_allow_mask(&g_procs, me, 0x2); // bit 1
    proc_set_kcall_mask(&g_procs, me, 0x1); // bit 0

    if !ipc_try_send(&g_procs, 1, 0, 0, 0, 0) { pass = 0; } // peer 1 permitted + live -> delivered
    if ipc_try_send(&g_procs, 2, 0, 0, 0, 0) { pass = 0; }  // peer 2 forbidden -> rejected

    switch kcall(&g_procs, 0, 42) { // op 0 permitted
        ok(v) => { if v != 42 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    switch kcall(&g_procs, 1, 42) { // op 1 forbidden -> Denied
        ok(v) => { pass = 0; }
        err(e) => {}
    }
    return pass;
}
