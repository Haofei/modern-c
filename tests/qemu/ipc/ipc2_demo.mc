// IPC completeness: multi-slot mailbox + source filtering + async notify. Two clients
// queue messages in the server's mailbox; the server uses ipc_receive_from to take
// client B's message before client A's (even though A's arrived first), then drains
// A's, then a non-blocking notify from B.

import "kernel/core/process.mc";
import "kernel/arch/riscv64/idle.mc";
import "kernel/core/ipc.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const STACK_SIZE: usize = 8192;
const SERVER_PID: u32 = 1;
const A_PID: u32 = 2;
const B_PID: u32 = 3;
const TAG_DATA: u32 = 1;
const TAG_PING: u32 = 7;

global g_procs: ProcTable;
global g_pass: u32;

fn server() -> void {
    var pass: u32 = 1;
    var m: Message = message_zero();
    ipc_receive_from(&g_procs, B_PID, &m); // source filter: B's message first
    if m.from != B_PID { pass = 0; }
    if m.a0 != 20 { pass = 0; }
    ipc_receive(&g_procs, &m); // then A's queued data
    if m.a0 != 10 { pass = 0; }
    ipc_receive(&g_procs, &m); // then B's async notify
    if m.tag != TAG_PING { pass = 0; }
    g_pass = pass;
    proc_exit(&g_procs, 0);
}

fn client_a() -> void {
    ipc_send(&g_procs, SERVER_PID, TAG_DATA, 10, 0, 0);
    proc_exit(&g_procs, 0);
}
fn client_b() -> void {
    ipc_send(&g_procs, SERVER_PID, TAG_DATA, 20, 0, 0);
    let sent: bool = ipc_notify(&g_procs, SERVER_PID, TAG_PING); // non-blocking
    proc_exit(&g_procs, 0);
}

fn alloc_stack(h: *mut Heap) -> usize {
    let base: PAddr = heap_alloc(h, STACK_SIZE, 16);
    return pa_value(base) + STACK_SIZE;
}

export fn ipc2_demo(region_base: usize, region_len: usize) -> u32 {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    proc_table_init(&g_procs);
    install_idle(&g_procs); // wfi when nothing runnable
    g_pass = 0;
    proc_spawn(&g_procs, alloc_stack(&heap), server);   // pid 1
    proc_spawn(&g_procs, alloc_stack(&heap), client_a); // pid 2
    proc_spawn(&g_procs, alloc_stack(&heap), client_b); // pid 3
    var done: u32 = 0;
    while done < 3 {
        switch proc_wait(&g_procs, 0) {
            ok(info) => { done = done + 1; }
            err(e) => { done = 3; }
        }
    }
    return g_pass;
}
