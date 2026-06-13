// TCP as a user-mode server: the TCP connection state machine runs in a server process;
// a client drives a passive-open handshake (LISTEN, then SYN, then ACK) entirely through
// kernel IPC, and the connection reaches ESTABLISHED — TCP as an isolated service.

import "kernel/core/process.mc";
import "kernel/arch/riscv64/idle.mc";
import "kernel/core/ipc.mc";
import "kernel/core/heap.mc";
import "kernel/net/tcp_conn.mc";
import "std/addr.mc";

const STACK_SIZE: usize = 8192;
const SERVER_PID: u32 = 1;
const TAG_LISTEN: u32 = 1;
const TAG_SEG: u32 = 2;
const TAG_STOP: u32 = 9;
const TAG_REPLY: u32 = 100;
const FLAG_SYN: u64 = 0x02;
const FLAG_ACK: u64 = 0x10;

global g_procs: ProcTable;
global g_conn: TcpConn;
global g_result: u32;

fn state_code(s: TcpState) -> u32 {
    switch s {
        .Closed => { return 0; }
        .Listen => { return 1; }
        .SynSent => { return 2; }
        .SynReceived => { return 3; }
        .Established => { return 4; }
        .FinWait1 => { return 5; }
        .FinWait2 => { return 6; }
        .CloseWait => { return 7; }
        .LastAck => { return 8; }
        .TimeWait => { return 9; }
    }
}

fn tcp_server() -> void {
    tcp_conn_init(&g_conn, 1000);
    var running: bool = true;
    while running {
        var req: Message = message_zero();
        ipc_receive(&g_procs, &req);
        if req.tag == TAG_STOP {
            running = false;
        } else {
            if req.tag == TAG_LISTEN {
                tcp_listen(&g_conn);
            }
            if req.tag == TAG_SEG {
                let act: TcpAction = tcp_on_segment(&g_conn, req.a0 as u16, req.a1 as u32);
            }
            ipc_reply(&g_procs, &req, TAG_REPLY, state_code(g_conn.state) as u64, 0, 0);
        }
    }
    proc_exit(&g_procs, 0);
}

fn client() -> void {
    var pass: u32 = 1;
    var rep: Message = message_zero();
    ipc_call(&g_procs, SERVER_PID, TAG_LISTEN, 0, 0, 0, &rep);
    if rep.a0 != 1 { pass = 0; }                                  // Listen
    ipc_call(&g_procs, SERVER_PID, TAG_SEG, FLAG_SYN, 100, 0, &rep);
    if rep.a0 != 3 { pass = 0; }                                  // SynReceived
    ipc_call(&g_procs, SERVER_PID, TAG_SEG, FLAG_ACK, 101, 0, &rep);
    if rep.a0 != 4 { pass = 0; }                                  // Established
    g_result = pass;
    ipc_send(&g_procs, SERVER_PID, TAG_STOP, 0, 0, 0);
    proc_exit(&g_procs, 0);
}

fn alloc_stack(h: *mut Heap) -> usize {
    let base: PAddr = heap_alloc(h, STACK_SIZE, 16);
    return pa_value(base) + STACK_SIZE;
}

export fn tcp_server_run(region_base: usize, region_len: usize) -> u32 {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    proc_table_init(&g_procs);
    install_idle(&g_procs); // wfi when nothing runnable
    g_result = 0;
    proc_spawn(&g_procs, alloc_stack(&heap), tcp_server);
    proc_spawn(&g_procs, alloc_stack(&heap), client);
    var done: u32 = 0;
    while done < 2 {
        switch proc_wait(&g_procs, 0) {
            ok(info) => { done = done + 1; }
            err(e) => { done = 2; }
        }
    }
    return g_result;
}
