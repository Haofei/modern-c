// Reincarnation: a supervisor restarts a crashed server, so a faulty service is
// recoverable instead of fatal — the MINIX reliability lesson. The server "crashes"
// (exits with a failure code) on its first life; the supervisor reaps it, sees the
// nonzero code, and re-spawns it; the second incarnation completes cleanly.

import "kernel/core/process.mc";
import "kernel/arch/riscv64/idle.mc";
import "kernel/core/console.mc";
import "kernel/core/heap.mc";
import "std/addr.mc";

const STACK_SIZE: usize = 8192;
const MAX_RESTARTS: u32 = 3;

global g_procs: ProcTable;
global g_incarnation: u32;
global g_completed: bool;

fn flaky_server() -> void {
    g_incarnation = g_incarnation + 1;
    if g_incarnation == 1 {
        console_putc('X'); // first life: crash
        proc_exit(&g_procs, 1); // nonzero = failure
    }
    console_putc('R'); // restarted incarnation: runs correctly
    g_completed = true;
    proc_exit(&g_procs, 0);
}

fn alloc_stack(h: *mut Heap) -> usize {
    let base: PAddr = heap_alloc(h, STACK_SIZE, 16);
    return pa_value(base) + STACK_SIZE;
}

// Supervise the server: on a failed exit, reincarnate it (bounded). Returns the
// number of restarts performed (expect 1).
export fn restart_demo(region_base: usize, region_len: usize) -> u32 {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    proc_table_init(&g_procs);
    install_idle(&g_procs); // wfi when nothing runnable
    g_incarnation = 0;
    g_completed = false;
    var restarts: u32 = 0;

    proc_spawn(&g_procs, alloc_stack(&heap), flaky_server);
    var supervising: bool = true;
    while supervising {
        switch proc_wait(&g_procs, 0) {
            ok(info) => {
                let code: u32 = info.code;
                if code != 0 {
                    if restarts < MAX_RESTARTS {
                        restarts = restarts + 1;
                        proc_spawn(&g_procs, alloc_stack(&heap), flaky_server); // reincarnate
                    } else {
                        supervising = false; // give up
                    }
                } else {
                    supervising = false; // clean exit — service done
                }
            }
            err(e) => {
                supervising = false;
            }
        }
    }
    return restarts;
}
