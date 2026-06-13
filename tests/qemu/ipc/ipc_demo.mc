// Microkernel IPC: a user-mode "doubler" service and a client communicate only through
// kernel-mediated messages (ipc_send/ipc_receive) — no shared memory, no direct calls.
// The kernel stamps the sender pid (`from`) so the server can reply. This is the
// MINIX-style backbone: services run as ordinary processes; the kernel routes messages.

import "kernel/core/process.mc";
import "kernel/arch/riscv64/idle.mc";
import "kernel/core/ipc.mc";
import "kernel/core/console.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const STACK_SIZE: usize = 8192;
const SERVER_PID: u32 = 1; // first spawned process
const TAG_REQUEST: u32 = 1;
const TAG_REPLY: u32 = 2;
const TAG_STOP: u32 = 9;

global g_procs: ProcTable;
global g_result: u32;

// The service: handle requests (reply a0*2) until a STOP message, then exit.
fn server() -> void {
    var running: bool = true;
    while running {
        var req: Message = message_zero();
        ipc_receive(&g_procs, &req);
        if req.tag == TAG_STOP {
            running = false;
        } else {
            console_putc('S'); // served one request
            ipc_reply(&g_procs, &req, TAG_REPLY, req.a0 * 2, 0, 0);
        }
    }
    proc_exit(&g_procs, 0);
}

// The client: request that the service double 21, check the reply, then stop it.
fn client() -> void {
    console_putc('C');
    var reply: Message = message_zero();
    ipc_call(&g_procs, SERVER_PID, TAG_REQUEST, 21, 0, 0, &reply); // sendrec
    g_result = reply.a0 as u32; // expect 42
    console_putc('R'); // got the reply
    ipc_send(&g_procs, SERVER_PID, TAG_STOP, 0, 0, 0);
    proc_exit(&g_procs, 0);
}

fn alloc_stack(h: *mut Heap) -> usize {
    let base: PAddr = heap_alloc(h, STACK_SIZE, 16);
    return pa_value(base) + STACK_SIZE;
}

export fn ipc_demo(region_base: usize, region_len: usize) -> u32 {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    proc_table_init(&g_procs);
    install_idle(&g_procs); // wfi when nothing runnable
    g_result = 0;
    proc_spawn(&g_procs, alloc_stack(&heap), server); // pid 1
    proc_spawn(&g_procs, alloc_stack(&heap), client); // pid 2

    // Wait for both to finish; proc_wait yields internally, running the server and
    // client (and their IPC rendezvous) until each exits.
    var done: u32 = 0;
    while done < 2 {
        switch proc_wait(&g_procs, 0) {
            ok(info) => {
                done = done + 1;
            }
            err(e) => {
                done = 2; // no more children — stop
            }
        }
    }
    return g_result; // 42 if the round-trip worked
}
