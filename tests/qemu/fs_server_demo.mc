// Filesystem migrated to a user-mode server. The FS server owns the VFS (over ramfs)
// and serves open/write/read/close over IPC; clients never call the FS directly. This
// is the MINIX VFS-server pattern: file operations cross an IPC boundary.

import "kernel/core/process.mc";
import "kernel/core/ipc.mc";
import "kernel/fs/vfs.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const STACK_SIZE: usize = 8192;
const FS_PID: u32 = 1;
const TAG_OPEN: u32 = 1;  // a0=name addr, a1=name len  -> reply a0 = fd
const TAG_WRITE: u32 = 2; // a0=fd, a1=data addr, a2=len -> reply a0 = bytes written
const TAG_READ: u32 = 3;  // a0=fd, a1=buf addr, a2=len  -> reply a0 = bytes read
const TAG_STOP: u32 = 9;
const TAG_REPLY: u32 = 100;
const FAIL: u64 = 0xFFFF_FFFF;

global g_procs: ProcTable;
global g_vfs: Vfs;
global g_name: [5]u8;
global g_data: [2]u8;
global g_rbuf: [4]u8;
global g_verify: u32;

fn fs_server() -> void {
    vfs_init(&g_vfs);
    var running: bool = true;
    while running {
        var req: Message = message_zero();
        ipc_receive(&g_procs, &req);
        var rc: u64 = FAIL;
        if req.tag == TAG_STOP {
            running = false;
        } else {
            if req.tag == TAG_OPEN {
                switch vfs_open(&g_vfs, req.a0 as usize, req.a1 as usize) {
                    ok(fd) => { rc = fd as u64; }
                    err(e) => {}
                }
            }
            if req.tag == TAG_WRITE {
                switch vfs_write(&g_vfs, req.a0 as usize, req.a1 as usize, req.a2 as usize) {
                    ok(n) => { rc = n as u64; }
                    err(e) => {}
                }
            }
            if req.tag == TAG_READ {
                switch vfs_read(&g_vfs, req.a0 as usize, req.a1 as usize, req.a2 as usize) {
                    ok(n) => { rc = n as u64; }
                    err(e) => {}
                }
            }
            ipc_send(&g_procs, req.from, TAG_REPLY, rc, 0, 0);
        }
    }
    proc_exit(&g_procs, 0);
}

// Send one FS request and return the server's reply value.
fn fs_call(tag: u32, a0: u64, a1: u64, a2: u64) -> u64 {
    ipc_send(&g_procs, FS_PID, tag, a0, a1, a2);
    var reply: Message = message_zero();
    ipc_receive(&g_procs, &reply);
    return reply.a0;
}

fn client() -> void {
    g_name[0] = 0x62; g_name[1] = 0x6F; g_name[2] = 0x6F; g_name[3] = 0x74; g_name[4] = 0; // "boot"
    g_data[0] = 0x4F; g_data[1] = 0x4B; // "OK"
    let name: u64 = ((&g_name[0]) as usize) as u64;
    let data: u64 = ((&g_data[0]) as usize) as u64;
    let rbuf: u64 = ((&g_rbuf[0]) as usize) as u64;

    let fd: u64 = fs_call(TAG_OPEN, name, 4, 0);
    let w: u64 = fs_call(TAG_WRITE, fd, data, 2);
    let rfd: u64 = fs_call(TAG_OPEN, name, 4, 0); // re-open for a fresh read position
    let n: u64 = fs_call(TAG_READ, rfd, rbuf, 4);

    var pass: u32 = 1;
    if w != 2 { pass = 0; }
    if n != 2 { pass = 0; }
    if g_rbuf[0] != 0x4F { pass = 0; } // 'O'
    if g_rbuf[1] != 0x4B { pass = 0; } // 'K'
    g_verify = pass;

    ipc_send(&g_procs, FS_PID, TAG_STOP, 0, 0, 0);
    proc_exit(&g_procs, 0);
}

fn alloc_stack(h: *mut Heap) -> usize {
    let base: PAddr = heap_alloc(h, STACK_SIZE, 16);
    return pa_value(base) + STACK_SIZE;
}

export fn fs_server_demo(region_base: usize, region_len: usize) -> u32 {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    proc_table_init(&g_procs);
    g_verify = 0;
    proc_spawn(&g_procs, alloc_stack(&heap), fs_server);
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
