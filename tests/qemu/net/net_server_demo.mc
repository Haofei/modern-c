// Network stack migrated to a user-mode server. The net server owns the UDP socket
// table and serves bind / deliver / recv over IPC; clients reach the network only
// through messages. (A real NIC driver would also be its own server feeding INJECT;
// here the client injects a datagram to exercise the demux + recv path end to end.)

import "kernel/core/process.mc";
import "kernel/arch/riscv64/idle.mc";
import "kernel/core/ipc.mc";
import "kernel/net/udp_socket.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const STACK_SIZE: usize = 8192;
const NET_PID: u32 = 1;
const TAG_BIND: u32 = 1;   // a0=sock idx, a1=port
const TAG_INJECT: u32 = 2; // a0=dst port, a1=payload addr, a2=len
const TAG_RECV: u32 = 3;   // a0=sock idx, a1=buf addr, a2=max -> reply a0 = length
const TAG_STOP: u32 = 9;
const TAG_REPLY: u32 = 100;

global g_procs: ProcTable;
global g_socks: SocketTable;
global g_payload: [8]u8;
global g_rbuf: [8]u8;
global g_verify: u32;

fn net_server() -> void {
    socket_table_init(&g_socks);
    var running: bool = true;
    while running {
        var req: Message = message_zero();
        ipc_receive(&g_procs, &req);
        var rc: u64 = 0;
        if req.tag == TAG_STOP {
            running = false;
        } else {
            if req.tag == TAG_BIND {
                switch socket_bind(&g_socks, req.a0 as usize, req.a1 as u16) {
                    ok(b) => { rc = 1; }
                    err(e) => {}
                }
            }
            if req.tag == TAG_INJECT {
                switch socket_deliver(&g_socks, req.a0 as u16, 0x0A00_0202, 5000, req.a1 as usize, req.a2 as usize) {
                    ok(b) => { rc = 1; }
                    err(e) => {}
                }
            }
            if req.tag == TAG_RECV {
                switch socket_recv(&g_socks, req.a0 as usize, req.a1 as usize, req.a2 as usize) {
                    ok(n) => { rc = n; }
                    err(e) => { rc = 0xFFFF_FFFF; }
                }
            }
            ipc_reply(&g_procs, &req, TAG_REPLY, rc, 0, 0);
        }
    }
    proc_exit(&g_procs, 0);
}

fn net_call(tag: u32, a0: u64, a1: u64, a2: u64) -> u64 {
    ipc_send(&g_procs, NET_PID, tag, a0, a1, a2);
    var reply: Message = message_zero();
    ipc_receive(&g_procs, &reply);
    return reply.a0;
}

fn client() -> void {
    g_payload[0] = 0x4E; g_payload[1] = 0x45; g_payload[2] = 0x54; g_payload[3] = 0x21; // "NET!"
    let pay: u64 = ((&g_payload[0]) as usize) as u64;
    let rbuf: u64 = ((&g_rbuf[0]) as usize) as u64;

    let bound: u64 = net_call(TAG_BIND, 0, 1234, 0);
    let injected: u64 = net_call(TAG_INJECT, 1234, pay, 4);
    let n: u64 = net_call(TAG_RECV, 0, rbuf, 8);

    var pass: u32 = 1;
    if bound != 1 { pass = 0; }
    if injected != 1 { pass = 0; }
    if n != 4 { pass = 0; }
    if g_rbuf[0] != 0x4E { pass = 0; } // 'N'
    if g_rbuf[3] != 0x21 { pass = 0; } // '!'
    g_verify = pass;

    ipc_send(&g_procs, NET_PID, TAG_STOP, 0, 0, 0);
    proc_exit(&g_procs, 0);
}

fn alloc_stack(h: *mut Heap) -> usize {
    let base: PAddr = heap_alloc(h, STACK_SIZE, 16);
    return pa_value(base) + STACK_SIZE;
}

export fn net_server_demo(region_base: usize, region_len: usize) -> u32 {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    proc_table_init(&g_procs);
    install_idle(&g_procs); // wfi when nothing runnable
    g_verify = 0;
    proc_spawn(&g_procs, alloc_stack(&heap), net_server);
    proc_spawn(&g_procs, alloc_stack(&heap), client);
    var done: u32 = 0;
    while done < 2 {
        switch proc_wait(&g_procs, 0) {
            ok(info) => { done = done + 1; }
            err(e) => { done = 2; }
        }
    }
    return g_verify;
}
