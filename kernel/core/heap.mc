// kernel/core/heap — a bump byte allocator over a physical memory region.
//
// Sub-allocates aligned byte ranges from a `PhysRange` the platform reserved for
// the kernel (distinct from the frame allocator, which hands out reclaimable page
// frames). All address math is typed/checked via std/addr — no raw `usize`, no
// hand-rolled alignment or overflow. v1 is bump-only (no per-allocation free); a
// free-list / slab is the next step.

import "std/addr.mc";

struct Heap {
    range: PhysRange,
    next: PAddr,
}

// Build a heap over a physical region (e.g. a frame range reserved at boot).
export fn heap_new(range: PhysRange) -> Heap {
    return .{ .range = range, .next = pr_start(&range) };
}

// Allocate `size` bytes aligned to `align` (a power of two). Traps if the heap is
// exhausted (callers gate on `heap_available`). Returns the allocation's physical
// address.
export fn heap_alloc(h: *mut Heap, size: usize, align: usize) -> PAddr {
    let start: PAddr = pa_align_up(h.next, align);
    let next: PAddr = pa_offset(start, size); // checked: traps on overflow
    if pa_lt(pr_end(&h.range), next) {
        unreachable; // heap exhausted
    }
    h.next = next;
    return start;
}

// Bytes still available between the bump frontier and the end of the region.
export fn heap_available(h: *mut Heap) -> usize {
    return pa_diff(h.next, pr_end(&h.range));
}
