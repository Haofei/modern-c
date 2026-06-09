import "kernel/lib/proc_snapshot.mc";
global g_t: ProcTable;
global g_snap: Snapshot;
fn worker() -> void {}
export fn snapshot_run() -> u32 {
    var pass: u32 = 1;
    proc_table_init(&g_t);
    let a: u32 = proc_spawn(&g_t, 0x1000, worker);
    let b: u32 = proc_spawn(&g_t, 0x2000, worker);
    if a != 1 { pass = 0; }
    if b != 2 { pass = 0; }

    snapshot_take(&g_t, &g_snap);
    if snapshot_count(&g_snap) != 3 { pass = 0; }    // bootstrap + 2 spawned
    if snapshot_pid(&g_snap, 0) != 0 { pass = 0; }   // bootstrap pid 0
    if snapshot_pid(&g_snap, 1) != 1 { pass = 0; }
    if snapshot_state(&g_snap, 0) != 2 { pass = 0; } // bootstrap Running(2)
    if snapshot_state(&g_snap, 1) != 1 { pass = 0; } // spawned Ready(1)
    if snapshot_count_state(&g_snap, 1) != 2 { pass = 0; } // two Ready
    if snapshot_count_state(&g_snap, 2) != 1 { pass = 0; } // one Running

    // stability: mutate the live table after the snapshot; the snapshot must not change
    let c: u32 = proc_spawn(&g_t, 0x3000, worker); // live table grows to 4
    if c != 3 { pass = 0; }                          // 3rd spawn -> slot 3
    if proc_count(&g_t) != 4 { pass = 0; }           // live changed
    if snapshot_count(&g_snap) != 3 { pass = 0; }    // snapshot stable
    return pass;
}
