import "kernel/lib/supervisor.mc";
import "kernel/lib/registry.mc";
import "std/mask.mc";

const NAME_PM: u32 = 0x504D;  // process manager (core)
const NAME_NET: u32 = 0x4E45; // net driver (restartable)

// A stand-in for proc_spawn: each call returns a fresh pid (the service's new incarnation).
struct Spawner { next_pid: u32 }
global g_spawner: Spawner;
fn spawn_service(s: *mut Spawner) -> u32 {
    s.next_pid = s.next_pid + 1;
    return s.next_pid;
}

global g_sup: Supervisor;
global g_reg: Registry;

export fn supervisor_run() -> u32 {
    var pass: u32 = 1;
    supervisor_init(&g_sup);
    registry_init(&g_reg);
    g_spawner.next_pid = 11; // initial net endpoint is 11; the next respawn yields 12

    let pm: ServiceManifest = .{ .name_key = NAME_PM, .endpoint = 1,
        .allowed_ipc = mask32_from(0xFFFF_FFFF), .allowed_kcalls = mask32_from(0xFFFF_FFFF),
        .restart = .Never, .priority = 9 };
    let net: ServiceManifest = .{ .name_key = NAME_NET, .endpoint = 11,
        .allowed_ipc = mask32_from(0x6), .allowed_kcalls = mask32_from(0x3),
        .restart = .OnFailure, .priority = 5 };
    var pm_idx: usize = 0;
    var net_idx: usize = 0;
    switch supervisor_register(&g_sup, pm, bind(&g_spawner, spawn_service)) { ok(i) => { pm_idx = i; } err(e) => { pass = 0; } }
    switch supervisor_register(&g_sup, net, bind(&g_spawner, spawn_service)) { ok(i) => { net_idx = i; } err(e) => { pass = 0; } }

    // started: register the net endpoint in the registry
    switch registry_add(&g_reg, NAME_NET, 11, 0) { ok(s) => {} err(e) => { pass = 0; } }
    switch supervisor_start(&g_sup, pm_idx) { ok(b) => {} err(e) => { pass = 0; } }
    switch supervisor_start(&g_sup, net_idx) { ok(b) => {} err(e) => { pass = 0; } }
    switch registry_find(&g_reg, NAME_NET) { ok(ep) => { if ep != 11 { pass = 0; } } err(e) => { pass = 0; } }

    // the net driver crashes -> the supervisor RESPAWNS it (new pid) and updates the registry
    switch supervisor_mark_failed(&g_sup, net_idx) { ok(b) => {} err(e) => { pass = 0; } }
    if supervisor_tick(&g_sup, &g_reg) != 1 { pass = 0; }      // one respawned
    if supervisor_restarts(&g_sup, net_idx) != 1 { pass = 0; }
    if supervisor_endpoint(&g_sup, net_idx) != 12 { pass = 0; } // manifest now points at the new pid
    // the registry resolves the name to the NEW endpoint; the old (11) is gone, not duplicated
    switch registry_find(&g_reg, NAME_NET) { ok(ep) => { if ep != 12 { pass = 0; } } err(e) => { pass = 0; } }
    if registry_count_key(&g_reg, NAME_NET) != 1 { pass = 0; }

    // a core service crash is still Fatal: not respawned
    switch supervisor_mark_failed(&g_sup, pm_idx) { ok(b) => {} err(e) => { pass = 0; } }
    if supervisor_tick(&g_sup, &g_reg) != 0 { pass = 0; }
    switch supervisor_restart(&g_sup, pm_idx, &g_reg) {
        ok(b) => { pass = 0; }
        err(e) => {}
    }

    // ----- dependency-ordered start -----
    // Register C, B, A out of order with C->B->A dependencies. `start_ordered` must spawn in
    // dependency order A, B, C; the spawner hands out increasing pids, so
    // endpoint(A) < endpoint(B) < endpoint(C) proves the order.
    supervisor_init(&g_sup);
    g_spawner.next_pid = 100;
    let ma: ServiceManifest = dep_manifest(0xA);
    let mb: ServiceManifest = dep_manifest(0xB);
    let mc: ServiceManifest = dep_manifest(0xC);
    var ia: usize = 0;
    var ib: usize = 0;
    var ic: usize = 0;
    switch supervisor_register(&g_sup, mc, bind(&g_spawner, spawn_service)) { ok(i) => { ic = i; } err(e) => { pass = 0; } }
    switch supervisor_register(&g_sup, mb, bind(&g_spawner, spawn_service)) { ok(i) => { ib = i; } err(e) => { pass = 0; } }
    switch supervisor_register(&g_sup, ma, bind(&g_spawner, spawn_service)) { ok(i) => { ia = i; } err(e) => { pass = 0; } }
    switch supervisor_set_dep(&g_sup, ic, 0xB) { ok(b) => {} err(e) => { pass = 0; } } // C depends on B
    switch supervisor_set_dep(&g_sup, ib, 0xA) { ok(b) => {} err(e) => { pass = 0; } } // B depends on A
    switch supervisor_start_ordered(&g_sup) {
        ok(n) => { if n != 3 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    let ea: u32 = supervisor_endpoint(&g_sup, ia);
    let eb: u32 = supervisor_endpoint(&g_sup, ib);
    let ec: u32 = supervisor_endpoint(&g_sup, ic);
    if ea >= eb { pass = 0; } // A spawned before B
    if eb >= ec { pass = 0; } // B spawned before C

    // ----- a dependency cycle is rejected (not partially started) -----
    supervisor_init(&g_sup);
    g_spawner.next_pid = 200;
    var ix: usize = 0;
    var iy: usize = 0;
    switch supervisor_register(&g_sup, dep_manifest(0xD), bind(&g_spawner, spawn_service)) { ok(i) => { ix = i; } err(e) => { pass = 0; } }
    switch supervisor_register(&g_sup, dep_manifest(0xE), bind(&g_spawner, spawn_service)) { ok(i) => { iy = i; } err(e) => { pass = 0; } }
    switch supervisor_set_dep(&g_sup, ix, 0xE) { ok(b) => {} err(e) => { pass = 0; } } // D -> E
    switch supervisor_set_dep(&g_sup, iy, 0xD) { ok(b) => {} err(e) => { pass = 0; } } // E -> D (cycle)
    switch supervisor_start_ordered(&g_sup) {
        ok(n) => { pass = 0; }  // a cycle must not start
        err(e) => {}            // DepUnsatisfied — correctly rejected
    }

    return pass;
}

// A minimal manifest (no privileges, restartable) for the dependency-ordering tests.
fn dep_manifest(key: u32) -> ServiceManifest {
    return .{ .name_key = key, .endpoint = 0,
        .allowed_ipc = mask32_from(0), .allowed_kcalls = mask32_from(0),
        .restart = .OnFailure, .priority = 1 };
}
