// kernel/core/heap — a reclaiming byte allocator over a physical memory region.
//
// Sub-allocates aligned byte ranges from a `PhysRange` the platform reserved for
// the kernel (distinct from the frame allocator, which hands out reclaimable page
// frames). All address math is typed/checked via std/addr — no raw `usize`, no
// hand-rolled alignment or overflow.
//
// Reclamation: a first-fit free list reuses freed blocks; what is never reused is
// carved from the bump frontier at the tail. `heap_free` returns a block to the
// list and coalesces it with adjacent free blocks (and with the bump frontier, so
// a free at the tail simply lowers the frontier). The free-list metadata lives in a
// fixed-capacity array *inside* the Heap (not in the freed memory), so freeing never
// touches the freed bytes and the allocator works on any backing store.
//
// Limitations: the free list has a fixed capacity (`HEAP_FREE_SLOTS`). Coalescing
// keeps the live count low in practice; if a free would exceed capacity *and* could
// not coalesce, the block is dropped (leaked back to nothing) rather than corrupting
// state — fail-safe, never fail-unsafe. First-fit is O(n) in the number of free
// blocks, which is fine for the small block counts a kernel heap sees.

import "std/addr.mc";
import "std/alloc.mc";

// Max distinct (non-coalesced) free blocks tracked at once. A kernel heap fragments
// little; coalescing collapses adjacent frees, so this rarely fills.
const HEAP_FREE_SLOTS: usize = 64;

// One free region [start, start+len). `len == 0` marks an empty slot.
struct FreeBlock {
    start: PAddr,
    len: usize,
}

struct Heap {
    range: PhysRange,
    next: PAddr, // bump frontier: [next, range.end) is untouched tail
    free: [HEAP_FREE_SLOTS]FreeBlock,
}

// An empty free slot.
fn fb_empty() -> FreeBlock {
    return .{ .start = pa(0), .len = 0 };
}

// Build a heap over a physical region (e.g. a frame range reserved at boot).
export fn heap_new(range: PhysRange) -> Heap {
    var h: Heap = uninit;
    h.range = range;
    h.next = pr_start(&range);
    var i: usize = 0;
    while i < HEAP_FREE_SLOTS {
        h.free[i] = fb_empty();
        i = i + 1;
    }
    return h;
}

// ----- free-list internals -----

// Drop a block back into the free list, coalescing with any adjacent free blocks and
// with the bump frontier. Fail-safe: if the list is full and the block can't coalesce,
// it is dropped rather than corrupting the list.
fn heap_release(h: *mut Heap, start: PAddr, len: usize) -> void {
    if len == 0 {
        return;
    }
    var bstart: PAddr = start;
    var blen: usize = len;
    var bend: PAddr = pa_offset(bstart, blen);

    // Coalesce with adjacent free blocks until no more merges are possible, then
    // (if the block now ends at the bump frontier) give it back to the tail.
    var changed: bool = true;
    while changed {
        changed = false;

        // If this block ends exactly at the bump frontier, return it to the tail
        // (lower the frontier) and absorb any free blocks now tail-adjacent.
        if pa_eq(bend, h.next) {
            h.next = bstart;
            var j: usize = 0;
            while j < HEAP_FREE_SLOTS {
                if h.free[j].len != 0 {
                    let fend: PAddr = pa_offset(h.free[j].start, h.free[j].len);
                    if pa_eq(fend, h.next) {
                        h.next = h.free[j].start;
                        h.free[j] = fb_empty();
                        j = 0;
                        continue;
                    }
                }
                j = j + 1;
            }
            return;
        }

        // Coalesce with an existing free block adjacent on either side.
        var i: usize = 0;
        while i < HEAP_FREE_SLOTS {
            if h.free[i].len != 0 {
                let fstart: PAddr = h.free[i].start;
                let fend: PAddr = pa_offset(fstart, h.free[i].len);
                if pa_eq(fend, bstart) {
                    // existing block sits just before the released one
                    bstart = fstart;
                    blen = blen + h.free[i].len;
                    bend = pa_offset(bstart, blen);
                    h.free[i] = fb_empty();
                    changed = true;
                    break;
                }
                if pa_eq(bend, fstart) {
                    // existing block sits just after the released one
                    blen = blen + h.free[i].len;
                    bend = pa_offset(bstart, blen);
                    h.free[i] = fb_empty();
                    changed = true;
                    break;
                }
            }
            i = i + 1;
        }
    }

    // Couldn't merge into the tail; store in a free slot.
    var k: usize = 0;
    while k < HEAP_FREE_SLOTS {
        if h.free[k].len == 0 {
            h.free[k] = .{ .start = bstart, .len = blen };
            return;
        }
        k = k + 1;
    }
    // Free list full and no coalesce was possible: drop the block (fail-safe leak).
    return;
}

// ----- public allocator -----

// Allocate `size` bytes aligned to `align` (a power of two). Reuses a freed block
// when one fits after alignment, else carves from the untouched tail. Traps if the
// heap is exhausted (callers gate on `heap_available`). Returns the allocation's
// physical address.
export fn heap_alloc(h: *mut Heap, size: usize, align: usize) -> PAddr {
    // First-fit over the free list: pick the first block whose aligned start still
    // leaves `size` bytes inside the block.
    var i: usize = 0;
    while i < HEAP_FREE_SLOTS {
        if h.free[i].len != 0 {
            let fstart: PAddr = h.free[i].start;
            let fend: PAddr = pa_offset(fstart, h.free[i].len);
            let astart: PAddr = pa_align_up(fstart, align);
            // astart could pass fend if alignment overshoots the block.
            if pa_le(astart, fend) {
                let aend: PAddr = pa_offset(astart, size); // checked
                if pa_le(aend, fend) {
                    // Carve [astart, aend) out of this block. Clear the slot, then
                    // release the head gap [fstart, astart) and tail remainder
                    // [aend, fend) back (each coalesces/restores as appropriate).
                    h.free[i] = fb_empty();
                    if pa_lt(fstart, astart) {
                        heap_release(h, fstart, pa_diff(fstart, astart));
                    }
                    if pa_lt(aend, fend) {
                        heap_release(h, aend, pa_diff(aend, fend));
                    }
                    return astart;
                }
            }
        }
        i = i + 1;
    }

    // No free block fit: carve from the bump frontier.
    let start: PAddr = pa_align_up(h.next, align);
    let next: PAddr = pa_offset(start, size); // checked: traps on overflow
    if pa_lt(pr_end(&h.range), next) {
        unreachable; // heap exhausted
    }
    // The alignment gap [h.next, start) is unused tail; once we advance past it, it
    // can never be reached by the frontier again, so return it to the free list.
    if pa_lt(h.next, start) {
        let gap: usize = pa_diff(h.next, start);
        let gstart: PAddr = h.next;
        h.next = next;
        heap_release(h, gstart, gap);
        return start;
    }
    h.next = next;
    return start;
}

// Return a block to the heap so a later `alloc` can reuse it. Validates the request
// (fail closed on a bogus free), then releases [addr, addr+size) to the free list,
// coalescing with adjacent free space. The signature matches the Allocator's free
// closure once `h` is captured.
export fn heap_free(h: *mut Heap, addr: PAddr, size: usize) -> void {
    if !pr_contains(&h.range, addr) {
        unreachable; // freeing an address this heap never owned
    }
    if size > pr_len(&h.range) {
        unreachable; // nonsensical size
    }
    if size == 0 {
        return;
    }
    let end: PAddr = pa_offset(addr, size); // checked
    if pa_lt(pr_end(&h.range), end) {
        unreachable; // block runs past the end of the region
    }
    // A free above the current frontier would be a free of never-allocated memory.
    if pa_lt(h.next, end) {
        unreachable;
    }
    heap_release(h, addr, size);
}

// Bytes still available: the untouched tail plus everything on the free list.
export fn heap_available(h: *mut Heap) -> usize {
    var total: usize = pa_diff(h.next, pr_end(&h.range));
    var i: usize = 0;
    while i < HEAP_FREE_SLOTS {
        total = total + h.free[i].len;
        i = i + 1;
    }
    return total;
}

// View this heap as a generic `Allocator`: the alloc/free closures capture `h`, so
// callers allocate against an `*Allocator` without knowing it's a kernel heap.
// `heap_alloc`/`heap_free` are already (env, …) -> …, so they bind directly.
export fn heap_allocator(h: *mut Heap) -> Allocator {
    return .{
        .alloc = bind(h, heap_alloc),
        .free = bind(h, heap_free),
    };
}
