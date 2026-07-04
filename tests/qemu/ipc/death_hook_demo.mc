// Process-death global resource cleanup. A microkernel installs ONE death hook on the
// process table; when any process dies, proc_death_cleanup runs it with (pid, gen) so
// every subsystem holding per-owner resources can drop what the dead process owned. Here
// the hook revokes the dead pid's memory grants and unregisters its services — proving a
// dead owner's grants/services cannot outlive it. The process table itself stays
// decoupled from granttab/registry; only this hook ties them together.

import "kernel/core/process.mc";
import "kernel/lib/granttab.mc";
import "kernel/lib/registry.mc";
import "std/addr.mc";

global g_t: ProcTable;
global g_grants: GrantTable;
global g_reg: Registry;

// The hook's captured environment: the two subsystem tables to clean up.
struct CleanupEnv { grants: *mut GrantTable, reg: *mut Registry }
global g_cleanup_env: CleanupEnv;

// Revoke everything the dead pid owned. (Counts returned by the revoke calls are
// ignored — the hook's contract is "leave nothing owned by `pid`".)
fn on_death(pid: u32, gen: u32) -> void {
    let revoked: usize = grant_table_revoke_owner(g_cleanup_env.grants, pid, gen);
    let dropped: usize = registry_unregister_endpoint(g_cleanup_env.reg, pid);
}

fn worker() -> void {}

const SVC_KEY: u32 = 0x100;

export fn death_hook_run() -> u32 {
    var pass: u32 = 1;
    proc_table_init(&g_t);
    grant_table_init(&g_grants);
    registry_init(&g_reg);

    g_cleanup_env.grants = &g_grants;
    g_cleanup_env.reg = &g_reg;
    proc_set_death_hook(&g_t, on_death);

    // A spawned process gives the dying bootstrap (pid 0) somewhere to switch to.
    let w: u32 = proc_spawn(&g_t, 0x1000, worker);

    // The bootstrap (pid 0) owns a memory grant and a registered service.
    var gid: usize = 0;
    switch grant_table_make(&g_grants, 0, 0, pa(0x4000), 256) { // owner endpoint (pid 0, gen 0)
        ok(id) => { gid = id; }
        err(e) => { pass = 0; }
    }
    switch registry_add(&g_reg, SVC_KEY, 0, 1) { // endpoint 0 == pid 0
        ok(slot) => {}
        err(e) => { pass = 0; }
    }

    // Issue a grant ref and confirm it opens *before* death; revoke invalidates the
    // grant's generation, so the same ref must fail to open *after* the owner dies.
    switch grant_table_ref(&g_grants, gid) {
        ok(r) => {
            switch grant_table_open(&g_grants, gid, r) {
                ok(b) => {}                  // live before death
                err(e) => { pass = 0; }
            }
            switch registry_find(&g_reg, SVC_KEY) {
                ok(ep) => { if ep != 0 { pass = 0; } }
                err(e) => { pass = 0; }      // registered before death
            }

            // The bootstrap exits -> death cleanup fires the hook for (pid 0, gen 0).
            proc_exit(&g_t, 0);

            // The dead owner's grant is revoked and its service unregistered.
            switch grant_table_open(&g_grants, gid, r) {
                ok(b) => { pass = 0; }       // still openable -> hook did not revoke
                err(e) => {}                 // Revoked: correct
            }
            switch registry_find(&g_reg, SVC_KEY) {
                ok(ep) => { pass = 0; }      // still registered -> hook did not unregister
                err(e) => {}
            }
        }
        err(e) => { pass = 0; }
    }
    return pass;
}
