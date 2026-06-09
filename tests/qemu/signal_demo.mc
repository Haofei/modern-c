// Signals: one process delivers an async signal to another, which polls its pending
// set, takes the signal, and acts on it. This is the kernel primitive a Process
// Manager would build POSIX signal delivery (handlers, default actions) on.

import "kernel/core/process.mc";
import "kernel/arch/riscv64/idle.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const STACK_SIZE: usize = 8192;
const TARGET_PID: u32 = 1;
const SIG_USR: u32 = 5;

global g_procs: ProcTable;
global g_taken: u32;

// The target: wait until a signal is pending, then take and record it.
fn target() -> void {
    g_taken = 99;
    while proc_sigpending(&g_procs) == 0 {
        proc_yield(&g_procs);
    }
    g_taken = proc_sigtake(&g_procs); // lowest pending signal
    proc_exit(&g_procs, 0);
}

// The signaller: deliver SIG_USR to the target.
fn signaller() -> void {
    proc_kill(&g_procs, TARGET_PID, SIG_USR);
    proc_exit(&g_procs, 0);
}

fn alloc_stack(h: *mut Heap) -> usize {
    let base: PAddr = heap_alloc(h, STACK_SIZE, 16);
    return pa_value(base) + STACK_SIZE;
}

export fn signal_demo(region_base: usize, region_len: usize) -> u32 {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    proc_table_init(&g_procs);
    install_idle(&g_procs); // wfi when nothing runnable
    g_taken = 0;
    proc_spawn(&g_procs, alloc_stack(&heap), target);    // pid 1
    proc_spawn(&g_procs, alloc_stack(&heap), signaller); // pid 2
    var done: u32 = 0;
    while done < 2 {
        switch proc_wait(&g_procs, 0) {
            ok(info) => { done = done + 1; }
            err(e) => { done = 2; }
        }
    }
    return g_taken; // expect SIG_USR (5)
}
