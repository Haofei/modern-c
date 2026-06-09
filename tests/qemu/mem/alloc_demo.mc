// Allocate through the type-erased Allocator interface (std/alloc), backed by a bump
// Heap captured in the alloc/free closures — generic code never names "Heap".

import "std/alloc.mc";
import "std/addr.mc";
import "kernel/core/heap.mc";

global g_pool: [8192]u8;

// Returns 1 iff two allocations via the generic Allocator advance and stay aligned.
export fn alloc_demo_run() -> u32 {
    let base: usize = (&g_pool[0]) as usize;
    var heap: Heap = heap_new(phys_range(pa(base), 8192));
    var a: Allocator = heap_allocator(&heap); // closures capture &heap (this frame)

    let p1: usize = pa_value(alloc_bytes(&a, 100, 16));
    let p2: usize = pa_value(alloc_bytes(&a, 8, 32));

    if p1 < base {
        return 0;
    }
    if (p1 % 16) != 0 {
        return 0;
    }
    if p2 < (p1 + 100) {
        return 0;
    }
    if (p2 % 32) != 0 {
        return 0;
    }
    free_bytes(&a, pa(p1), 100); // no-op for a bump heap, but exercises the interface
    return 1;
}
