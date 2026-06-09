// Enforced service manifests: a manifest's declared privileges (IPC allowlist, kcall mask,
// priority) are APPLIED to the process, after which the kernel's existing checks (ipc_try_send
// / kcall) enforce them. Manifest = the single source of truth for what a service may do.
import "kernel/core/process.mc";
import "kernel/lib/supervisor.mc";
import "std/mask.mc";

global g_t: ProcTable;
global g_sup: Supervisor;
global g_dummy: u32;
fn worker() -> void {}
fn nospawn(s: *mut u32) -> u32 { return 0; } // dummy spawner (this service never restarts)

export fn manifest_run() -> u32 {
    var pass: u32 = 1;
    proc_table_init(&g_t);
    let a: u32 = proc_spawn(&g_t, 0x1000, worker); // pid 1 (a permitted peer)
    let b: u32 = proc_spawn(&g_t, 0x2000, worker); // pid 2 (a forbidden peer)
    if a != 1 { pass = 0; }
    if b != 2 { pass = 0; }
    supervisor_init(&g_sup);

    // a manifest: may IPC only peer 1 (bit 1) and invoke only kcall op 0 (bit 0)
    let m: ServiceManifest = .{ .name_key = 1, .endpoint = 0,
        .allowed_ipc = mask32_from(0x2), .allowed_kcalls = mask32_from(0x1),
        .restart = .Never, .priority = 3 };
    var idx: usize = 0;
    switch supervisor_register(&g_sup, m, bind(&g_dummy, nospawn)) {
        ok(ri) => { idx = ri; }
        err(re) => { pass = 0; }
    }

    // APPLY the manifest's privileges to the (bootstrap) process — the enforcement wiring
    proc_set_allow_mask(&g_t, 0, supervisor_allowed_ipc(&g_sup, idx));
    proc_set_kcall_mask(&g_t, 0, supervisor_allowed_kcalls(&g_sup, idx));
    proc_set_priority(&g_t, 0, m.priority);

    // now the kernel enforces the declared privileges:
    if !ipc_try_send(&g_t, 1, 5, 0, 0, 0) { pass = 0; } // peer 1 permitted (bit set + live)
    if ipc_try_send(&g_t, 2, 5, 0, 0, 0) { pass = 0; }  // peer 2 denied (bit clear)
    switch kcall(&g_t, 0, 0) {                          // kcall op 0 permitted
        ok(v0) => {}
        err(e0) => { pass = 0; }
    }
    switch kcall(&g_t, 1, 0) {                          // kcall op 1 denied
        ok(v1) => { pass = 0; }
        err(e1) => {}
    }
    return pass;
}
