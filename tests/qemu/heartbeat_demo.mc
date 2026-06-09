// Reincarnation with heartbeat liveness: a supervisor expects periodic heartbeats from
// a worker (via ipc_notify) and uses ipc_receive_timeout to detect a missed beat. The
// first worker instance crashes without beating; the supervisor times out, restarts it;
// the second instance heartbeats and signals done. Composes notify + timeout + restart.

import "kernel/core/process.mc";
import "kernel/arch/riscv64/idle.mc";
import "kernel/core/ipc.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const STACK_SIZE: usize = 8192;
const MAX_RESTARTS: u32 = 3;
const SUPERVISOR_PID: u32 = 0;
const TAG_HEARTBEAT: u32 = 1;
const TAG_DONE: u32 = 2;

global g_procs: ProcTable;
global g_gen: u32;

fn worker() -> void {
    g_gen = g_gen + 1;
    if g_gen == 1 {
        proc_exit(&g_procs, 1); // crash: no heartbeat sent
    }
    let h: bool = ipc_notify(&g_procs, SUPERVISOR_PID, TAG_HEARTBEAT);
    let d: bool = ipc_notify(&g_procs, SUPERVISOR_PID, TAG_DONE);
    proc_exit(&g_procs, 0);
}

fn alloc_stack(h: *mut Heap) -> usize {
    let base: PAddr = heap_alloc(h, STACK_SIZE, 16);
    return pa_value(base) + STACK_SIZE;
}

export fn heartbeat_demo(region_base: usize, region_len: usize) -> u32 {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    proc_table_init(&g_procs);
    install_idle(&g_procs); // wfi when nothing runnable
    g_gen = 0;
    var restarts: u32 = 0;
    var healthy: bool = false;

    proc_spawn(&g_procs, alloc_stack(&heap), worker); // gen 1
    var supervising: bool = true;
    while supervising {
        var m: Message = message_zero();
        let got: bool = ipc_receive_timeout(&g_procs, &m, 8);
        if got {
            if m.tag == TAG_DONE {
                healthy = true;
                supervising = false;
            }
        } else {
            // missed heartbeat -> worker is dead/hung -> reap + reincarnate
            switch proc_reap(&g_procs, 0) {
                ok(x) => {}
                err(e) => {}
            }
            if restarts < MAX_RESTARTS {
                restarts = restarts + 1;
                proc_spawn(&g_procs, alloc_stack(&heap), worker); // restart
            } else {
                supervising = false;
            }
        }
    }
    switch proc_reap(&g_procs, 0) {
        ok(x) => {}
        err(e) => {}
    }
    if healthy {
        return restarts; // expect 1
    }
    return 0;
}
