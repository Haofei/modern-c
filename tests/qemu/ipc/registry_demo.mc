// Name/registry server (MINIX Data Store pattern): services register under a key; a
// client looks a service up by key to get its pid, then talks to it — no hardcoded
// pids. Here an echo service registers itself, the client finds it by name and round-
// trips a value, then shuts both down.

import "kernel/core/process.mc";
import "kernel/arch/riscv64/idle.mc";
import "kernel/core/ipc.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const STACK_SIZE: usize = 8192;
const REGISTRY_PID: u32 = 1;
const REG_REGISTER: u32 = 1; // a0=key, a1=pid
const REG_LOOKUP: u32 = 2;   // a0=key -> reply a0=pid (0 if absent)
const REG_STOP: u32 = 9;
const TAG_REPLY: u32 = 100;
const TAG_ECHO: u32 = 1;
const TAG_DONE: u32 = 8;
const KEY_ECHO: u64 = 0xEC0;

global g_procs: ProcTable;
global g_keys: [8]u64;
global g_pids: [8]u32;
global g_reg_count: usize;
global g_result: u32;

fn registry_server() -> void {
    g_reg_count = 0;
    var running: bool = true;
    while running {
        var req: Message = message_zero();
        ipc_receive(&g_procs, &req);
        if req.tag == REG_STOP {
            running = false;
        } else {
            if req.tag == REG_REGISTER {
                g_keys[g_reg_count] = req.a0;
                g_pids[g_reg_count] = req.a1 as u32;
                g_reg_count = g_reg_count + 1;
                ipc_send(&g_procs, req.from, TAG_REPLY, 1, 0, 0);
            }
            if req.tag == REG_LOOKUP {
                var found: u32 = 0;
                var i: usize = 0;
                while i < g_reg_count {
                    if g_keys[i] == req.a0 {
                        found = g_pids[i];
                    }
                    i = i + 1;
                }
                ipc_send(&g_procs, req.from, TAG_REPLY, found as u64, 0, 0);
            }
        }
    }
    proc_exit(&g_procs, 0);
}

fn echo_service() -> void {
    let me: u32 = proc_pid(&g_procs);
    var reply: Message = message_zero();
    ipc_call(&g_procs, REGISTRY_PID, REG_REGISTER, KEY_ECHO, me as u64, 0, &reply); // register self
    var running: bool = true;
    while running {
        var req: Message = message_zero();
        ipc_receive(&g_procs, &req);
        if req.tag == TAG_DONE {
            running = false;
        } else {
            ipc_send(&g_procs, req.from, TAG_REPLY, req.a0, 0, 0); // echo the payload
        }
    }
    proc_exit(&g_procs, 0);
}

fn client() -> void {
    var reply: Message = message_zero();
    ipc_call(&g_procs, REGISTRY_PID, REG_LOOKUP, KEY_ECHO, 0, 0, &reply);
    let svc: u32 = reply.a0 as u32; // the echo service's pid, found by name
    ipc_call(&g_procs, svc, TAG_ECHO, 1234, 0, 0, &reply);
    g_result = reply.a0 as u32; // 1234 echoed back
    ipc_send(&g_procs, svc, TAG_DONE, 0, 0, 0);
    ipc_send(&g_procs, REGISTRY_PID, REG_STOP, 0, 0, 0);
    proc_exit(&g_procs, 0);
}

fn alloc_stack(h: *mut Heap) -> usize {
    let base: PAddr = heap_alloc(h, STACK_SIZE, 16);
    return pa_value(base) + STACK_SIZE;
}

export fn registry_demo(region_base: usize, region_len: usize) -> u32 {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    proc_table_init(&g_procs);
    install_idle(&g_procs); // wfi when nothing runnable
    g_result = 0;
    proc_spawn(&g_procs, alloc_stack(&heap), registry_server); // pid 1
    proc_spawn(&g_procs, alloc_stack(&heap), echo_service);    // pid 2
    proc_spawn(&g_procs, alloc_stack(&heap), client);          // pid 3
    var done: u32 = 0;
    while done < 3 {
        switch proc_wait(&g_procs, 0) {
            ok(info) => { done = done + 1; }
            err(e) => { done = 3; }
        }
    }
    return g_result;
}
