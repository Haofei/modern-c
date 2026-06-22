// Host driver for kernel/core/heap.mc — exercises aligned bump allocation,
// distinct/contiguous allocations, alignment, and available-bytes accounting
// over a real pool, entirely in MC so no C-side struct mirror of `Heap` is
// needed (the C harness only supplies the pool + trap/ksan stubs).
//
// `heap_host_test` builds a Heap over [pool_start, pool_start+pool_len), runs
// every check the old hand-mirrored C driver made, and returns 0 on success or
// a small nonzero id of the FIRST failed check. The caller passes a page-aligned
// pool whose length matches the original driver (8192 bytes) so the exact
// address arithmetic below holds.

import "std/addr.mc";
import "kernel/core/heap.mc";

export fn heap_host_test(pool_start: usize, pool_len: usize) -> u32 {
    let range: PhysRange = phys_range(pa(pool_start), pool_len);
    var h: Heap = heap_new(range);

    // (1) A fresh heap has the whole pool available.
    if heap_available(&h) != pool_len {
        return 1;
    }

    // (2) First alloc starts at the (already 64-aligned) base.
    let a: PAddr = heap_alloc(&h, 100, 16);
    if !pa_eq(a, pa(pool_start)) {
        return 2;
    }
    // (3) ...and is 16-aligned.
    if !pa_is_aligned(a, 16) {
        return 3;
    }

    // (4) Next alloc is aligned up past a's 100 bytes: align_up(base+100, 64)
    //     = base+128, and is 64-aligned.
    let b: PAddr = heap_alloc(&h, 8, 64);
    if !pa_is_aligned(b, 64) {
        return 4;
    }
    // Hoist the checked arithmetic into a typed `let`: the C backend can only
    // recover a checked-add's target type from an explicit binding, not from a
    // bare subexpression in comparison position.
    let expect_b: usize = pool_start + 128;
    if !pa_eq(b, pa(expect_b)) {
        return 5;
    }
    // (6) b is distinct from and above a.
    if !pa_lt(a, b) {
        return 6;
    }

    // (7) Only the bytes actually carved are unavailable: a's 100 + b's 8 = 108.
    //     The 28-byte alignment gap [base+100, base+128) is reclaimed onto the
    //     free list, so availability drops by exactly 108, not 136.
    let used: usize = 100 + 8;
    let expect_avail: usize = pool_len - used;
    if heap_available(&h) != expect_avail {
        return 7;
    }

    return 0;
}
