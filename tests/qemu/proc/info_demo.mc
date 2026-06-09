// Info/snapshot service: top/ps query a service over IPC instead of poking process internals.
// Built on the kernel/lib service loop + proc_snapshot (a stable, race-free table view). The
// handler answers count/pid/state queries from a captured snapshot.
import "kernel/lib/service.mc";
import "kernel/lib/proc_snapshot.mc";
import "kernel/core/process.mc";
import "kernel/core/ipc.mc";

const Q_COUNT: u32 = 1;
const Q_PID: u32 = 2;
const Q_STATE: u32 = 3;

struct InfoEnv { snap: Snapshot }
global g_info: InfoEnv;
global g_t: ProcTable;
fn worker() -> void {}

fn info_handle(e: *mut InfoEnv, req: Message) -> Reply {
    if req.tag == Q_COUNT {
        return reply(Q_COUNT, snapshot_count(&e.snap) as u64);
    }
    if req.tag == Q_PID {
        return reply(Q_PID, snapshot_pid(&e.snap, req.a0 as usize) as u64);
    }
    if req.tag == Q_STATE {
        return reply(Q_STATE, snapshot_state(&e.snap, req.a0 as usize) as u64);
    }
    return reply(0, 0); // unknown query
}

export fn info_run() -> u32 {
    var pass: u32 = 1;
    proc_table_init(&g_t);
    let a: u32 = proc_spawn(&g_t, 0x1000, worker); // pid 1
    let b: u32 = proc_spawn(&g_t, 0x2000, worker); // pid 2
    if a != 1 { pass = 0; }
    if b != 2 { pass = 0; }

    // the info service captures a stable snapshot, then answers queries over IPC
    snapshot_take(&g_t, &g_info.snap);
    let h: closure(Message) -> Reply = bind(&g_info, info_handle);
    var rep: Message = message_zero();

    // process count
    if !ipc_send_try(&g_t, 0, Q_COUNT, 0, 0, 0) { pass = 0; }
    if service_step(&g_t, h) != Q_COUNT { pass = 0; }
    ipc_receive(&g_t, &rep);
    if rep.a0 != 3 { pass = 0; } // bootstrap + 2 spawned

    // pid at index 1
    if !ipc_send_try(&g_t, 0, Q_PID, 1, 0, 0) { pass = 0; }
    if service_step(&g_t, h) != Q_PID { pass = 0; }
    ipc_receive(&g_t, &rep);
    if rep.a0 != 1 { pass = 0; }

    // state code of the bootstrap (index 0 -> Running = 2)
    if !ipc_send_try(&g_t, 0, Q_STATE, 0, 0, 0) { pass = 0; }
    if service_step(&g_t, h) != Q_STATE { pass = 0; }
    ipc_receive(&g_t, &rep);
    if rep.a0 != 2 { pass = 0; }
    return pass;
}
