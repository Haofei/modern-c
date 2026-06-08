// Process lifecycle with exit codes + reaping: the bootstrap spawns three
// processes, each prints its letter and `proc_exit`s with a distinct code, becoming
// a Zombie. The bootstrap yields once to run them; when all have exited control
// returns, and it `proc_reap`s each child, printing the reaped exit codes. Output
// "ABC123" proves all three ran (ABC) and all three were waited on with their codes
// (123). Returns the number reaped.

import "kernel/core/process.mc";
import "kernel/core/console.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const STACK_SIZE: usize = 8192;

global g_procs: ProcTable;

fn proc_a() -> void {
    console_putc('A');
    proc_exit(&g_procs, 1);
}
fn proc_b() -> void {
    console_putc('B');
    proc_exit(&g_procs, 2);
}
fn proc_c() -> void {
    console_putc('C');
    proc_exit(&g_procs, 3);
}

fn alloc_stack(h: *mut Heap) -> usize {
    let base: PAddr = heap_alloc(h, STACK_SIZE, 16);
    return pa_value(base) + STACK_SIZE;
}

// Block until one child of the bootstrap (pid 0) exits, reap it, and print its exit
// code. `proc_wait` yields internally to run the children. Returns 1 if reaped.
fn wait_one(t: *mut ProcTable) -> u32 {
    switch proc_wait(t, 0) {
        ok(info) => {
            let code: u32 = (info & 0x0000_0000_FFFF_FFFF) as u32;
            console_putc((('0' as u32) + code) as u8);
            return 1;
        }
        err(e) => {
            return 0;
        }
    }
}

export fn process_demo(region_base: usize, region_len: usize) -> u32 {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    proc_table_init(&g_procs);
    proc_spawn(&g_procs, alloc_stack(&heap), proc_a);
    proc_spawn(&g_procs, alloc_stack(&heap), proc_b);
    proc_spawn(&g_procs, alloc_stack(&heap), proc_c);

    // Blocking-wait for all three children (proc_wait runs them, then reaps each).
    var reaped: u32 = 0;
    reaped = reaped + wait_one(&g_procs);
    reaped = reaped + wait_one(&g_procs);
    reaped = reaped + wait_one(&g_procs);
    return reaped; // 3
}
