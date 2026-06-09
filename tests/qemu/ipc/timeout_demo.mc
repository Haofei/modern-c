// IPC timeout: a receiver that no one sends to must not block forever. ipc_receive_timeout
// polls a bounded number of yields and reports a timeout (false) instead of hanging.

import "kernel/core/process.mc";
import "kernel/arch/riscv64/idle.mc";
import "kernel/core/ipc.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const STACK_SIZE: usize = 8192;
global g_procs: ProcTable;
global g_result: u32; // 1 = timed out as expected

fn waiter() -> void {
    var m: Message = message_zero();
    let got: bool = ipc_receive_timeout(&g_procs, &m, 5); // nobody will send
    if got {
        g_result = 0; // unexpected message
    } else {
        g_result = 1; // timed out, as expected
    }
    proc_exit(&g_procs, 0);
}

fn alloc_stack(h: *mut Heap) -> usize {
    let base: PAddr = heap_alloc(h, STACK_SIZE, 16);
    return pa_value(base) + STACK_SIZE;
}

export fn timeout_demo(region_base: usize, region_len: usize) -> u32 {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    proc_table_init(&g_procs);
    install_idle(&g_procs); // wfi when nothing runnable
    g_result = 0;
    proc_spawn(&g_procs, alloc_stack(&heap), waiter);
    var done: u32 = 0;
    while done < 1 {
        switch proc_wait(&g_procs, 0) {
            ok(info) => { done = done + 1; }
            err(e) => { done = 1; }
        }
    }
    return g_result;
}
