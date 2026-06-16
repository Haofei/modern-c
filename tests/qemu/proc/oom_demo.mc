// LIVE reclaim / OOM-kill (kernel/core/process) — the agent-OS safety keystone. A runaway agent
// is the LIVE process that never calls proc_exit: it keeps charging memory and would OOM the host
// if nothing could reclaim it from the outside. This test drives that reclaim path on the host
// (the arch context primitives are stubbed by the C driver):
//   * three children A, B, C all spawn LIVE and never exit; C is charged WAY more memory than A,B
//     (C is the runaway);
//   * an over-quota charge against C fails closed (err(.OverQuota)) and reserves nothing;
//   * proc_oom_victim selects C — the highest-usage live, non-bootstrap offender;
//   * proc_oom_reclaim OOM-kills C: C becomes a non-live Zombie, its memory account is reset to
//     zero and its fds are released (reclaimed), while A and B stay LIVE with accounts intact —
//     the other agents survive;
//   * C, now a zombie, is reapable via proc_reap like any normal exit.

import "kernel/core/process.mc";
import "kernel/lib/resacct.mc";
import "kernel/lib/fdspace.mc";

global g_t: ProcTable;

fn worker() -> void {}

export fn oom_run() -> u32 {
    var pass: u32 = 1;
    proc_table_init(&g_t);

    // Spawn three children from the bootstrap (pid 0). All stay LIVE — none ever exits.
    let a: u32 = proc_spawn(&g_t, 0x1000, worker);
    let b: u32 = proc_spawn(&g_t, 0x2000, worker);
    let c: u32 = proc_spawn(&g_t, 0x3000, worker);
    let sa: usize = a as usize;
    let sb: usize = b as usize;
    let sc: usize = c as usize;

    // Charge memory: A and B modestly, C WAY more — C is the runaway / worst offender.
    switch proc_charge_mem(&g_t, sa, 1000) {
        ok(used) => { if used != 1000 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    switch proc_charge_mem(&g_t, sb, 2000) {
        ok(used) => { if used != 2000 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    let c_big: usize = 0x100000 - 16; // 16 units shy of C's default ceiling
    switch proc_charge_mem(&g_t, sc, c_big) {
        ok(used) => { if used != c_big { pass = 0; } }
        err(e) => { pass = 0; }
    }

    // Give C an open fd, to prove the kill releases its fd-space.
    switch fd_alloc(proc_fds(&g_t, sc), 1, 7) {
        ok(fd) => {}
        err(e) => { pass = 0; }
    }
    if fd_count(proc_fds(&g_t, sc)) == 0 { pass = 0; } // C holds an fd before the kill

    // --- over-quota: charging C past its limit fails closed, nothing reserved ---
    switch proc_charge_mem(&g_t, sc, 32) { // only 16 left -> over quota
        ok(used) => { pass = 0; }
        err(e) => { if e != .OverQuota { pass = 0; } }
    }
    if resacct_used(proc_macct(&g_t, sc)) != c_big { pass = 0; } // failed charge is a no-op

    // --- victim selection: C is the highest-usage live, non-bootstrap process ---
    switch proc_oom_victim(&g_t) {
        ok(v) => { if v != sc { pass = 0; } }
        err(e) => { pass = 0; }
    }

    // --- LIVE reclaim: kill the runaway, reclaim its resources ---
    switch proc_oom_reclaim(&g_t) {
        ok(slot) => { if slot != sc { pass = 0; } }
        err(e) => { pass = 0; }
    }

    // C is now a non-live Zombie with its memory + fds reclaimed.
    if proc_is_live(&g_t, sc) { pass = 0; }                  // C is no longer live
    if proc_state_code(&g_t, sc) != 4 { pass = 0; }          // 4 == Zombie
    if resacct_used(proc_macct(&g_t, sc)) != 0 { pass = 0; } // memory account reclaimed
    if fd_count(proc_fds(&g_t, sc)) != 0 { pass = 0; }       // fd-space released

    // The OTHER agents survive: A and B are STILL LIVE with their accounts intact.
    if !proc_is_live(&g_t, sa) { pass = 0; }
    if !proc_is_live(&g_t, sb) { pass = 0; }
    if resacct_used(proc_macct(&g_t, sa)) != 1000 { pass = 0; }
    if resacct_used(proc_macct(&g_t, sb)) != 2000 { pass = 0; }

    // --- C, a zombie, reaps like any normal death (the parent is the bootstrap, pid 0) ---
    switch proc_reap(&g_t, 0) {
        ok(info) => { if info.pid != c { pass = 0; } }
        err(e) => { pass = 0; }
    }

    return pass;
}
