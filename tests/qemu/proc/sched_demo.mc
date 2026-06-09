// A three-thread cooperative round-robin, demonstrating the kernel scheduler with
// per-thread stacks allocated from the kernel heap. Each thread prints its letter
// and yields; the scheduler rotates main -> A -> B -> C -> main, so each `main`
// yield produces "ABC".

import "kernel/core/sched.mc";
import "kernel/core/heap.mc";
import "kernel/core/console.mc";
import "std/addr.mc";

const STACK_SIZE: usize = 8192;
const ROUNDS: u32 = 3;

global g_sched: Scheduler;

fn thread_a() -> void {
    while true {
        console_putc('A');
        sched_yield(&g_sched);
    }
}
fn thread_b() -> void {
    while true {
        console_putc('B');
        sched_yield(&g_sched);
    }
}
fn thread_c() -> void {
    while true {
        console_putc('C');
        sched_yield(&g_sched);
    }
}

// Carve a stack from the heap and return its top (stacks grow down).
fn alloc_stack(h: *mut Heap) -> usize {
    let base: PAddr = heap_alloc(h, STACK_SIZE, 16);
    return pa_value(base) + STACK_SIZE;
}

export fn sched_demo(region_base: usize, region_len: usize) -> u32 {
    var heap: Heap = heap_new(phys_range(pa(region_base), region_len));
    sched_init(&g_sched);
    sched_spawn(&g_sched, alloc_stack(&heap), thread_a);
    sched_spawn(&g_sched, alloc_stack(&heap), thread_b);
    sched_spawn(&g_sched, alloc_stack(&heap), thread_c);

    var i: u32 = 0;
    while i < ROUNDS {
        sched_yield(&g_sched); // main -> A -> B -> C -> main: prints "ABC"
        i = i + 1;
    }
    return ROUNDS;
}
