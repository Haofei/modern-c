// Host-driver exercise for the reclaiming kernel heap (kernel/core/heap).
//
// Builds a heap over a fixed PhysRange (no real backing store is touched — the
// allocator only does typed address arithmetic and keeps its free list inside the
// Heap struct), then proves that `heap_free` genuinely reclaims:
//   1. alloc a block, free it, `heap_available` returns to baseline;
//   2. a long alloc/free loop does NOT monotonically shrink availability (no leak);
//   3. alloc two, free the first, alloc one that fits the hole -> the freed hole is
//      reused (the returned address is the freed block, availability doesn't drop
//      further beyond the reused block).
// Returns 1 only if every check passes.

import "std/addr.mc";
import "kernel/core/heap.mc";

const REGION_BASE: usize = 0x8000_0000;
const REGION_LEN: usize = 1 << 20; // 1 MiB

export fn heapfree_run() -> u32 {
    var h: Heap = heap_new(phys_range(pa(REGION_BASE), REGION_LEN));

    let baseline: usize = heap_available(&h);
    if baseline != REGION_LEN {
        return 0;
    }

    // ---- 1. alloc then free returns availability to baseline ----
    let a: PAddr = heap_alloc(&h, 4096, 16);
    if heap_available(&h) != baseline - 4096 {
        return 0;
    }
    heap_free(&h, a, 4096);
    if heap_available(&h) != baseline {
        return 0;
    }

    // ---- 2. many alloc/free cycles must not monotonically shrink ----
    // Without reclamation, each iteration would bump the frontier and availability
    // would fall by 4096 every loop; with reclamation it stays at baseline.
    var i: usize = 0;
    while i < 100000 {
        let p: PAddr = heap_alloc(&h, 4096, 16);
        heap_free(&h, p, 4096);
        if heap_available(&h) != baseline {
            return 0; // leaked: a freed block was not reclaimed
        }
        i = i + 1;
    }

    // ---- 3. free a hole between two live blocks, then reuse it ----
    let b0: PAddr = heap_alloc(&h, 1024, 16); // block we will free
    let b1: PAddr = heap_alloc(&h, 1024, 16); // stays live, pins b0's slot mid-heap
    let after_two: usize = heap_available(&h);
    if after_two != baseline - 2048 {
        return 0;
    }
    heap_free(&h, b0, 1024); // creates a 1024-byte hole below the live b1
    if heap_available(&h) != after_two + 1024 {
        return 0;
    }
    // A new 1024-byte alloc must reuse the freed hole (first-fit), not the tail.
    let b2: PAddr = heap_alloc(&h, 1024, 16);
    if pa_value(b2) != pa_value(b0) {
        return 0; // did not reuse the freed hole
    }
    if heap_available(&h) != after_two {
        return 0; // availability didn't return to the two-live-blocks level
    }

    // A partial reuse: free a big block, alloc a smaller one from it, the remainder
    // stays available.
    heap_free(&h, b1, 1024);
    heap_free(&h, b2, 1024);
    let before_split: usize = heap_available(&h);
    let s: PAddr = heap_alloc(&h, 256, 16);
    if heap_available(&h) != before_split - 256 {
        return 0;
    }
    heap_free(&h, s, 256);
    if heap_available(&h) != before_split {
        return 0;
    }

    return 1;
}
