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

// ----- KASAN shadow hooks (D2.1) -----
//
// A KASAN-profile heap (built with `heap_new_ksan`) drives a shadow map: it POISONS a
// block's bytes on `heap_free` and UNPOISONS the user bytes on `heap_alloc`. The shadow
// is consulted by the compiler-instrumented memory accesses (raw.load/raw.store under
// `--checks=ksan`) via `mc_ksan_check`, so a use-after-free or out-of-bounds ACCESS
// traps the moment it touches a poisoned byte — before the freed block is reused. These
// hooks are no-ops in a default heap (`ksan == 0`), so non-KASAN builds are unchanged.
//
// The shadow runtime (poison/unpoison/check) is provided externally and must itself be
// UNinstrumented (it manipulates the shadow with raw accesses); it lives in C in the
// boot runtime so the ksan profile never recurses through its own shadow writes.
extern fn mc_ksan_poison(addr: usize, size: usize) -> void;
extern fn mc_ksan_unpoison(addr: usize, size: usize) -> void;

// ----- redzone hardening (D2.4) -----
//
// A redzone-profile heap (built with `heap_new_redzoned`) reserves guard bytes
// immediately *before* and *after* every user allocation and fills them with a known
// poison pattern. A buffer overflow that writes past the user region lands in the
// trailing redzone; an underflow lands in the leading one. On `heap_free` (and via
// the explicit `heap_check_block`) the allocator re-reads both redzones, and if any
// poison byte has been clobbered it TRAPS (`unreachable`) instead of returning the
// corrupted block to the free list, where it would silently propagate.
//
// The default `heap_new` leaves `redzone == 0`, so a non-redzone build keeps the
// exact byte layout and free-list behaviour it had before — the guard work and the
// poison writes are entirely skipped (the profile is selected at heap construction).
//
// REDZONE_BYTES is the guard width on each side. POISON is the fill byte; it is
// deliberately not 0x00 so that an overflow which only zeroes memory is still caught.
const REDZONE_BYTES: usize = 16;
const REDZONE_POISON: u8 = 0xCD;

// Write the poison pattern across `[start, start+len)`.
fn redzone_fill(start: PAddr, len: usize) -> void {
    var i: usize = 0;
    while i < len {
        unsafe {
            raw.store<u8>(pa_offset(start, i), REDZONE_POISON);
        }
        i = i + 1;
    }
}

// Return true iff every byte of `[start, start+len)` still holds the poison pattern.
fn redzone_intact(start: PAddr, len: usize) -> bool {
    var i: usize = 0;
    while i < len {
        var b: u8 = 0;
        unsafe {
            b = raw.load<u8>(pa_offset(start, i));
        }
        if b != REDZONE_POISON {
            return false;
        }
        i = i + 1;
    }
    return true;
}

// One free region [start, start+len). `len == 0` marks an empty slot.
struct FreeBlock {
    start: PAddr,
    len: usize,
}

struct Heap {
    range: PhysRange,
    next: PAddr, // bump frontier: [next, range.end) is untouched tail
    free: [HEAP_FREE_SLOTS]FreeBlock,
    // Guard width (bytes) reserved on each side of every user allocation. 0 disables
    // the redzone profile entirely (default `heap_new`), so non-redzone builds keep
    // their original layout and incur no poison work.
    redzone: usize,
    // KASAN shadow profile (D2.1): 1 enables shadow poison/unpoison on free/alloc, 0
    // (default) disables it. Independent of `redzone`, though `heap_new_ksan` enables
    // both so freed blocks AND redzones are poisoned in the shadow.
    ksan: usize,
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
    h.redzone = 0; // redzone profile off: original layout, no guard bytes
    h.ksan = 0;    // KASAN shadow profile off: no poison/unpoison hooks
    var i: usize = 0;
    while i < HEAP_FREE_SLOTS {
        h.free[i] = fb_empty();
        i = i + 1;
    }
    return h;
}

// Build a heap with the redzone hardening profile enabled (D2.4). Every allocation
// is fenced by `REDZONE_BYTES` poison bytes on each side; overflow into a redzone is
// detected and trapped on free / `heap_check_block`. Same backing store, same API —
// the only difference is the guard bytes and the corruption check.
export fn heap_new_redzoned(range: PhysRange) -> Heap {
    var h: Heap = heap_new(range);
    h.redzone = REDZONE_BYTES;
    return h;
}

// Build a heap with the KASAN shadow hardening profile (D2.1). On top of the redzone
// profile (so guard bands are poisoned in the shadow too), every `heap_alloc` UNPOISONS
// the user region in the shadow and every `heap_free` POISONS the whole fenced block.
// Combined with compiler-instrumented accesses (`--checks=ksan`), a read or write of a
// freed (or out-of-bounds) byte traps at ACCESS time via `mc_ksan_check` — strictly
// finer than D2.4, which only catches a redzone clobber on FREE. The caller must arm the
// shadow region for this heap's backing store (`mc_ksan_arm`, runtime-side) first.
export fn heap_new_ksan(range: PhysRange) -> Heap {
    var h: Heap = heap_new_redzoned(range);
    h.ksan = 1;
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
//
// With the redzone profile (`h.redzone != 0`) the request is widened to fence the
// user region with guard bytes: a leading band rounded up to `align` (so the user
// pointer stays aligned) and a trailing band of `redzone` bytes, both filled with
// the poison pattern. The user pointer (raw_start + lead) is returned; `heap_free`
// reconstructs the bands from `redzone`/`align` and verifies the poison is intact.
// C2: heap allocation is a sleepable op (it may walk/coalesce the free list and,
// in a fuller kernel, block on memory pressure) — allocating from an
// `#[irq_context]` function is forbidden ("sleeping in interrupt").
#[may_sleep]
export fn heap_alloc(h: *mut Heap, size: usize, align: usize) -> PAddr {
    let rz: usize = h.redzone;
    if rz == 0 {
        return heap_alloc_raw(h, size, align);
    }
    // The leading guard is exactly `rz` bytes; for the user pointer to stay aligned
    // we therefore require `align <= rz` (rz is a power-of-two-friendly 16). Kernel
    // heap allocations are 16-aligned or finer, so this always holds; a larger align
    // is a misuse and fails closed.
    if align > rz {
        unreachable; // redzone profile supports align <= REDZONE_BYTES
    }
    // Request the fenced block [raw .. raw+rz+size+rz). `heap_alloc_raw` aligns `raw`
    // to `align`; since `rz` is a multiple of `align`, `raw+rz` (the user pointer) is
    // aligned too. Poison both guard bands, then hand back the user pointer.
    let inner: usize = rz + size + rz; // checked arithmetic via overflow traps
    let raw_start: PAddr = heap_alloc_raw(h, inner, align);
    let user: PAddr = pa_offset(raw_start, rz);
    // KASAN: unpoison the entire fenced block BEFORE filling the guards, so the heap's
    // own redzone writes never land on poisoned shadow (the block may be a reused, and
    // thus poisoned, freed block). The bands are re-poisoned in the shadow just below.
    if h.ksan != 0 {
        mc_ksan_unpoison(pa_value(raw_start), inner);
    }
    redzone_fill(raw_start, rz);                 // leading guard [raw_start, user)
    redzone_fill(pa_offset(user, size), rz);     // trailing guard [user+size, +rz)
    // KASAN: poison the two guard bands in the shadow (an OOB access into them traps at
    // access time, the access-time analogue of the free-time redzone check) and leave
    // the user region `[user, user+size)` valid/addressable.
    if h.ksan != 0 {
        mc_ksan_poison(pa_value(raw_start), rz);             // leading guard
        mc_ksan_poison(pa_value(pa_offset(user, size)), rz); // trailing guard
    }
    return user;
}

// Core aligned allocator (no redzone). The original `heap_alloc` body.
fn heap_alloc_raw(h: *mut Heap, size: usize, align: usize) -> PAddr {
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

// Verify the redzones fencing the user allocation `[addr, addr+size)` are intact.
// Traps (`unreachable`) the moment a guard byte has been overwritten — i.e. on the
// first detected heap buffer overflow/underflow. No-op for a non-redzone heap. Can
// be called at any point to check a live allocation, not only on free.
export fn heap_check_block(h: *mut Heap, addr: PAddr, size: usize) -> void {
    let rz: usize = h.redzone;
    if rz == 0 {
        return;
    }
    let lead: PAddr = pa(pa_value(addr) - rz); // [addr-rz, addr), checked subtraction
    if !redzone_intact(lead, rz) {
        unreachable; // underflow: leading redzone clobbered
    }
    if !redzone_intact(pa_offset(addr, size), rz) {
        unreachable; // overflow: trailing redzone clobbered
    }
}

// Return a block to the heap so a later `alloc` can reuse it. Validates the request
// (fail closed on a bogus free), then releases [addr, addr+size) to the free list,
// coalescing with adjacent free space. The signature matches the Allocator's free
// closure once `h` is captured.
//
// On a redzone heap, the user passes the same `(addr, size)` it received; this routine
// first verifies both guard bands (trapping on a detected overflow before the block
// re-enters the free list) and then releases the *fenced* block [addr-rz, addr+size+rz).
export fn heap_free(h: *mut Heap, addr: PAddr, size: usize) -> void {
    var faddr: PAddr = addr;
    var fsize: usize = size;
    let rz: usize = h.redzone;
    if rz != 0 && size != 0 {
        faddr = pa(pa_value(addr) - rz); // raw fenced start, checked subtraction
        fsize = rz + size + rz;          // full fenced length
        // KASAN: the redzone bands are POISONED in the shadow (so a user OOB access traps);
        // but `heap_check_block` below legitimately READS them, which would itself trap
        // under instrumentation. Unpoison the whole fenced block first so the heap's own
        // guard read is valid, then the block is re-poisoned wholesale just below.
        if h.ksan != 0 {
            mc_ksan_unpoison(pa_value(faddr), fsize);
        }
        heap_check_block(h, addr, size); // traps on corruption
    }
    if !pr_contains(&h.range, faddr) {
        unreachable; // freeing an address this heap never owned
    }
    if fsize > pr_len(&h.range) {
        unreachable; // nonsensical size
    }
    if fsize == 0 {
        return;
    }
    let end: PAddr = pa_offset(faddr, fsize); // checked
    if pa_lt(pr_end(&h.range), end) {
        unreachable; // block runs past the end of the region
    }
    // A free above the current frontier would be a free of never-allocated memory.
    if pa_lt(h.next, end) {
        unreachable;
    }
    // KASAN: poison the whole fenced block in the shadow. From here on, any ACCESS to
    // these bytes (a use-after-free read or write) consults the shadow via mc_ksan_check
    // and traps — the access-time detection that is strictly finer than the free-time
    // redzone check. Poison AFTER the redzone read above (which needs valid shadow) and
    // before release; the free-list metadata `heap_release` touches lives in the Heap
    // struct, not in these freed bytes, so it is never instrumented against this poison.
    if h.ksan != 0 {
        mc_ksan_poison(pa_value(faddr), fsize);
    }
    heap_release(h, faddr, fsize);
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
