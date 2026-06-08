// Storage driver migrated to a user-mode server. The block server owns the disk (a
// capability over the RAM-disk region) and serves READ/WRITE-block requests over IPC.
// Clients never touch the device — they send a block number + a buffer address and the
// server does the transfer. (Buffers are passed by address since servers share the
// kernel AS here; MINIX memory grants are the next step for separate address spaces.)

import "kernel/core/process.mc";
import "kernel/core/ipc.mc";
import "kernel/core/capability.mc";
import "kernel/core/heap.mc";
import "std/mem.mc";
import "std/addr.mc";

const STACK_SIZE: usize = 8192;
const BLOCK_SIZE: usize = 512;
const STORAGE_PID: u32 = 1;
const TAG_READ: u32 = 1;
const TAG_WRITE: u32 = 2;
const TAG_STOP: u32 = 9;
const TAG_REPLY: u32 = 100;

global g_procs: ProcTable;
global g_disk: [4096]u8; // the RAM disk (8 * 512), owned by the storage server
global g_wbuf: [512]u8;
global g_rbuf: [512]u8;
global g_verify: u32;

fn storage_server() -> void {
    var cap: Cap<usize> = cap_mint(usize, (&g_disk[0]) as usize); // granted the disk
    var running: bool = true;
    while running {
        var req: Message = message_zero();
        ipc_receive(&g_procs, &req);
        if req.tag == TAG_STOP {
            running = false;
        } else {
            let disk: usize = cap_resource(usize, &cap);
            let off: usize = (req.a0 as usize) * BLOCK_SIZE;
            let buf: usize = req.a1 as usize;
            if req.tag == TAG_WRITE {
                mem_copy(pa(disk + off), pa(buf), BLOCK_SIZE);
            } else {
                mem_copy(pa(buf), pa(disk + off), BLOCK_SIZE);
            }
            ipc_send(&g_procs, req.from, TAG_REPLY, 0, 0, 0);
        }
    }
    cap_revoke(usize, cap);
    proc_exit(&g_procs, 0);
}

fn client() -> void {
    var i: usize = 0;
    while i < BLOCK_SIZE {
        g_wbuf[i] = (i & 0xFF) as u8;
        i = i + 1;
    }
    let waddr: u64 = ((&g_wbuf[0]) as usize) as u64;
    let raddr: u64 = ((&g_rbuf[0]) as usize) as u64;
    var reply: Message = message_zero();
    ipc_send(&g_procs, STORAGE_PID, TAG_WRITE, 3, waddr, 0); // write block 3
    ipc_receive(&g_procs, &reply);
    ipc_send(&g_procs, STORAGE_PID, TAG_READ, 3, raddr, 0); // read it back
    ipc_receive(&g_procs, &reply);
    var pass: u32 = 1;
    var j: usize = 0;
    while j < BLOCK_SIZE {
        if g_rbuf[j] != g_wbuf[j] {
            pass = 0;
        }
        j = j + 1;
    }
    g_verify = pass;
    ipc_send(&g_procs, STORAGE_PID, TAG_STOP, 0, 0, 0);
    proc_exit(&g_procs, 0);
}

fn alloc_stack(h: *mut Heap) -> usize {
    let base: PAddr = heap_alloc(h, STACK_SIZE, 16);
    return pa_value(base) + STACK_SIZE;
}

export fn block_server_demo(region_base: usize, region_len: usize) -> u32 {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    proc_table_init(&g_procs);
    g_verify = 0;
    proc_spawn(&g_procs, alloc_stack(&heap), storage_server);
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
