// Per-process memory accounting (kernel/core/process). Each Process carries a memory
// ResourceAccount (macct) with an independent quota. This test drives the bookkeeping path on
// the host (the arch context primitives are stubbed by the C driver):
//   * each process's account is independent — a spawned child starts at zero usage, NOT
//     inheriting the parent's charged memory;
//   * charging fails closed — an over-quota charge returns err(.OverQuota) and reserves nothing;
//   * exit releases the account — a dead process's used memory drops back to zero.

import "kernel/core/process.mc";
import "kernel/lib/resacct.mc";

global g_t: ProcTable;

fn worker() -> void {}

export fn procmem_run() -> u32 {
    var pass: u32 = 1;
    proc_table_init(&g_t);

    // The bootstrap (pid 0, the current process) charges some memory against its account.
    switch resacct_charge(proc_macct(&g_t, 0), 1000) {
        ok(used) => { if used != 1000 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    if resacct_used(proc_macct(&g_t, 0)) != 1000 { pass = 0; }

    // --- spawn a child: its account starts at zero, independent of the parent's usage ---
    let child: u32 = proc_spawn(&g_t, 0x1000, worker);
    let cs: usize = child as usize;
    if resacct_used(proc_macct(&g_t, cs)) != 0 { pass = 0; } // fresh: did NOT inherit parent's 1000

    // The child charges up to near its full quota (the default is 0x100000 = 1048576).
    let near: usize = 0x100000 - 16; // 16 units shy of the ceiling
    switch resacct_charge(proc_macct(&g_t, cs), near) {
        ok(used) => { if used != near { pass = 0; } }
        err(e) => { pass = 0; }
    }
    // The parent's account is unaffected by the child's charge (independent accounts).
    if resacct_used(proc_macct(&g_t, 0)) != 1000 { pass = 0; }

    // --- charging over the remaining quota fails closed: nothing is reserved ---
    switch resacct_charge(proc_macct(&g_t, cs), 32) { // only 16 left -> over quota
        ok(used) => { pass = 0; }
        err(e) => { if e != .OverQuota { pass = 0; } }
    }
    if resacct_used(proc_macct(&g_t, cs)) != near { pass = 0; } // a failed charge is a no-op

    // --- exit releases the account: a zombie holds no charged memory ---
    // (On the host the context switch is a no-op stub, so proc_exit returns here; we set
    // `current` by hand to stand in for the scheduler having dispatched the child.)
    g_t.current = cs;
    proc_exit(&g_t, 0);                                  // child exits -> Zombie, account released
    if resacct_used(proc_macct(&g_t, cs)) != 0 { pass = 0; } // the dead child's usage is back to zero

    return pass;
}
