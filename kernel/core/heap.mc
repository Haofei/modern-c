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
import "std/alloc/alloc.mc";

// Max distinct (non-coalesced) free blocks tracked at once. A kernel heap fragments
// little; coalescing collapses adjacent frees, so this rarely fills.
const HEAP_FREE_SLOTS: usize = 64;
const HEAP_LIVE_SLOTS: usize = 256;

// Free-list coalesce strategy (Phase 2.1, perf refactor). The free list is kept in one
// of two representations, selected at compile time:
//
//   true  (NEW, default): the free slots are COMPACTED into `free[0..free_count)`.
//         `heap_release` coalesces in a SINGLE forward pass — it merges the (at most one)
//         predecessor and successor with an O(1) swap-remove each, then O(1)-appends the
//         merged block. This replaces the old multi-pass `while(changed)` re-scan and its
//         separate O(n) find-an-empty-slot scan (O(n^2)-flavoured per free under
//         fragmentation) with one bounded pass and O(1) insert/remove — no element shift.
//         (An address-sorted variant was measured too; its O(n) insert *shift* made the
//         well-optimized C backend slower, so the compacted swap-remove form was chosen.)
//
//   false (LEGACY): the original unsorted 64-slot array + `while(changed)` full re-scan.
//         Kept selectable as a fail-safe; both paths produce a fully-coalesced free list
//         with identical membership, differing only in first-fit slot *order*.
//
// Both representations share the same `free[]` / `heap_available` view, so availability
// accounting is unchanged. `free_count` is maintained only by the compacted path; the
// legacy path ignores it.
const HEAP_COMPACT_FREELIST: bool = true;

// One free region [start, start+len). `len == 0` marks an empty slot.
pub struct FreeBlock {
    start: PAddr,
    len: usize,
}

pub struct LiveBlock {
    start: PAddr,
    len: usize,
}

pub struct Heap {
    range: PhysRange,
    next: PAddr, // bump frontier: [next, range.end) is untouched tail
    free: [HEAP_FREE_SLOTS]FreeBlock,
    live: [HEAP_LIVE_SLOTS]LiveBlock,
    // Number of free (non-empty) blocks packed into `free[0..free_count)` when the
    // COMPACTED representation is active (`HEAP_COMPACT_FREELIST`). Slots at and above
    // `free_count` are empty. The legacy unsorted path does not maintain this.
    free_count: usize,
    // Exact live-allocation ownership tracking. Normal heaps keep this enabled so
    // double-free, partial-free, and overlap-free fail closed. Bump/frame pools that
    // allocate many fixed pages and never free them can explicitly disable this with
    // heap_init_untracked to avoid turning the inline live table into an artificial
    // frame-count ceiling.
    track_live: usize,
    // Exact ownership table for live user allocations. A free must match one
    // currently-live {addr, size} entry, which catches double-free, partial-free,
    // and overlapping-free attempts before the free-list can be corrupted.
    live_count: usize,
    // Capacity loss is never silent: if fixed metadata is exhausted, retain
    // the exact leaked-byte total for health policy/telemetry.
    dropped_free_bytes: usize,
}

// An empty free slot.
fn fb_empty() -> FreeBlock {
    return .{ .start = pa(0), .len = 0 };
}

fn lb_empty() -> LiveBlock {
    return .{ .start = pa(0), .len = 0 };
}

fn heap_empty_free_list() -> [HEAP_FREE_SLOTS]FreeBlock {
    return .{
        fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(),
        fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(),
        fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(),
        fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(),
        fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(),
        fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(),
        fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(),
        fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(), fb_empty(),
    };
}

fn heap_empty_live_list() -> [HEAP_LIVE_SLOTS]LiveBlock {
    return .{
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
        lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(), lb_empty(),
    };
}

// Build a heap over a physical region (e.g. a frame range reserved at boot).
pub fn heap_init(h: *mut Heap, range: PhysRange) -> void {
    h.range = range;
    h.next = pr_start(&range);
    h.free = heap_empty_free_list();
    h.free_count = 0;
    h.track_live = 1;
    h.live_count = 0;
    h.dropped_free_bytes = 0;
}

pub fn heap_init_untracked(h: *mut Heap, range: PhysRange) -> void {
    heap_init(h, range);
    h.track_live = 0;
}

pub fn heap_new(range: PhysRange) -> Heap {
    return .{
        .range = range,
        .next = pr_start(&range),
        .free = heap_empty_free_list(),
        .live = heap_empty_live_list(),
        .free_count = 0,
        .track_live = 1,
        .live_count = 0,
        .dropped_free_bytes = 0,
    };
}

// ----- free-list internals -----

// Drop a block back into the free list, coalescing with any adjacent free blocks and
// with the bump frontier. Fail-safe: if the list is full and the block can't coalesce,
// it is dropped rather than corrupting the list. Dispatches to the compacted (default)
// or legacy implementation per `HEAP_COMPACT_FREELIST`.
fn heap_release(h: *mut Heap, start: PAddr, len: usize) -> void {
    if HEAP_COMPACT_FREELIST {
        heap_release_compact(h, start, len);
        return;
    }
    heap_release_legacy(h, start, len);
}

// ----- compacted free-list helpers -----

// Swap-remove the block at slot `i` (0 <= i < free_count): move the last live entry into
// slot `i` and shrink the live count. O(1); the array is UNORDERED, so the reordering is
// harmless. Empties the vacated tail slot so `heap_available`'s len-sum view is unchanged.
fn fl_swap_remove(h: *mut Heap, i: usize) -> void {
    let last: usize = h.free_count - 1;
    h.free[i] = h.free[last];
    h.free[last] = fb_empty();
    h.free_count = last;
}

// Append [start, start+len) as a new live entry. O(1). If the list is already full the
// block is dropped (fail-safe leak, never corrupts the list). Callers coalesce first, so
// an appended block never abuts an existing one (preserving the no-adjacent invariant).
fn fl_append(h: *mut Heap, start: PAddr, len: usize) -> void {
    if h.free_count >= HEAP_FREE_SLOTS {
        if h.dropped_free_bytes > 0xFFFF_FFFF_FFFF_FFFF - len {
            h.dropped_free_bytes = 0xFFFF_FFFF_FFFF_FFFF;
        } else {
            h.dropped_free_bytes = h.dropped_free_bytes + len;
        }
        return; // fail-closed accounting; callers can trip health policy below
    }
    h.free[h.free_count] = .{ .start = start, .len = len };
    h.free_count = h.free_count + 1;
}

// Consume the free block at slot `i` (the allocator picked it to carve from). Under the
// compacted representation this swap-removes it (and decrements free_count); under the
// legacy representation it simply empties the slot. The caller has already read the
// block's start/len before calling.
fn fl_take_at(h: *mut Heap, i: usize) -> void {
    if HEAP_COMPACT_FREELIST {
        fl_swap_remove(h, i);
        return;
    }
    h.free[i] = fb_empty();
}

// Compacted release. The free list has no two adjacent blocks (fully coalesced on every
// release), so the block being freed has at most one immediate predecessor (its end ==
// block start) and one immediate successor (its start == block end). A SINGLE forward pass
// over `free[0..free_count)` finds and coalesces both — after a swap-remove the moved-in
// entry is re-checked at the same index, and because extending the block can only ever make
// it adjacent to the original two neighbours (no-adjacent invariant), no restart is needed.
// A frontier-adjacent result is handed back to the bump tail; otherwise it is O(1)-appended.
fn heap_release_compact(h: *mut Heap, start: PAddr, len: usize) -> void {
    if len == 0 {
        return;
    }
    var bstart: PAddr = start;
    var blen: usize = len;
    var bend: PAddr = pa_offset(bstart, blen);

    // Single pass: coalesce the (<= 2) adjacent free blocks via O(1) swap-removes.
    var i: usize = 0;
    while i < h.free_count {
        let fstart: PAddr = h.free[i].start;
        let fend: PAddr = pa_offset(fstart, h.free[i].len);
        // Exact duplicates and partial overlaps are allocator corruption, not
        // additional free capacity. This catches double-free of a non-frontier
        // block and any release overlapping an already-free interval.
        if pa_lt(bstart, fend) && pa_lt(fstart, bend) {
            unreachable;
        }
        var merged: bool = false;
        if pa_eq(fend, bstart) {
            // existing block sits just before the released one
            bstart = fstart;
            blen = blen + h.free[i].len;
            bend = pa_offset(bstart, blen);
            fl_swap_remove(h, i);
            merged = true;
        } else {
            if pa_eq(bend, fstart) {
                // existing block sits just after the released one
                blen = blen + h.free[i].len;
                bend = pa_offset(bstart, blen);
                fl_swap_remove(h, i);
                merged = true;
            }
        }
        // On a merge the swapped-in entry now occupies slot `i`; re-check it (do not
        // advance). Otherwise move on.
        if !merged {
            i = i + 1;
        }
    }

    // If the (possibly coalesced) block now ends at the bump frontier, return it to the
    // tail and absorb any free block left tail-adjacent (invariant bounds this to <= 1).
    if pa_eq(bend, h.next) {
        h.next = bstart;
        var j: usize = 0;
        while j < h.free_count {
            let jend: PAddr = pa_offset(h.free[j].start, h.free[j].len);
            if pa_eq(jend, h.next) {
                h.next = h.free[j].start;
                fl_swap_remove(h, j);
                j = 0;
                continue;
            }
            j = j + 1;
        }
        return;
    }

    // Store the merged block. Full + no coalesce => drop (fail-safe leak).
    fl_append(h, bstart, blen);
}

// ----- legacy (unsorted) free-list implementation -----

// The original multi-pass coalesce over the unsorted `free[]` array. Kept selectable via
// `HEAP_COMPACT_FREELIST == false` as a fail-safe fallback. Semantics identical to the
// compacted path (fully-coalesced free list); only the first-fit slot order differs.
fn heap_release_legacy(h: *mut Heap, start: PAddr, len: usize) -> void {
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
                if pa_lt(bstart, fend) && pa_lt(fstart, bend) {
                    unreachable;
                }
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

// ----- live-allocation ownership helpers -----

fn heap_live_overlaps(h: *mut Heap, start: PAddr, len: usize, skip: usize) -> bool {
    if len == 0 {
        return false;
    }
    let end: PAddr = pa_offset(start, len);
    var i: usize = 0;
    while i < h.live_count {
        if i != skip {
            let lstart: PAddr = h.live[i].start;
            let lend: PAddr = pa_offset(lstart, h.live[i].len);
            if pa_lt(start, lend) && pa_lt(lstart, end) {
                return true;
            }
        }
        i = i + 1;
    }
    return false;
}

fn heap_record_live(h: *mut Heap, start: PAddr, len: usize) -> void {
    if h.track_live == 0 {
        return;
    }
    if len == 0 {
        return;
    }
    if h.live_count >= HEAP_LIVE_SLOTS {
        unreachable; // refuse to create an allocation that cannot be owned
    }
    if heap_live_overlaps(h, start, len, HEAP_LIVE_SLOTS) {
        unreachable; // allocator produced overlapping live memory
    }
    h.live[h.live_count] = .{ .start = start, .len = len };
    h.live_count = h.live_count + 1;
}

fn heap_find_live(h: *mut Heap, start: PAddr, len: usize) -> usize {
    var i: usize = 0;
    while i < h.live_count {
        if pa_eq(h.live[i].start, start) && h.live[i].len == len {
            return i;
        }
        i = i + 1;
    }
    unreachable; // free/grow must exactly match a currently live allocation
}

fn heap_take_live(h: *mut Heap, start: PAddr, len: usize) -> void {
    if h.track_live == 0 {
        return;
    }
    if len == 0 {
        return;
    }
    let i: usize = heap_find_live(h, start, len);
    let last: usize = h.live_count - 1;
    h.live[i] = h.live[last];
    h.live[last] = lb_empty();
    h.live_count = last;
}

fn heap_resize_live(h: *mut Heap, start: PAddr, old_len: usize, new_len: usize) -> void {
    if h.track_live == 0 {
        return;
    }
    if old_len == new_len {
        return;
    }
    if old_len == 0 || new_len == 0 {
        unreachable; // in-place grow operates on an existing non-empty allocation
    }
    let i: usize = heap_find_live(h, start, old_len);
    if heap_live_overlaps(h, start, new_len, i) {
        unreachable;
    }
    h.live[i].len = new_len;
}

// ----- public allocator -----

// Allocate `size` bytes aligned to `align` (a power of two). Reuses a freed block
// when one fits after alignment, else carves from the untouched tail. Traps if the
// heap is exhausted (callers gate on `heap_available`). Returns the allocation's
// physical address.
//
// C2: heap allocation is a sleepable op (it may walk/coalesce the free list and,
// in a fuller kernel, block on memory pressure) — allocating from an
// `#[irq_context]` function is forbidden ("sleeping in interrupt").
#[may_sleep]
pub fn heap_alloc(h: *mut Heap, size: usize, align: usize) -> PAddr {
    if h.track_live != 0 && size != 0 && h.live_count >= HEAP_LIVE_SLOTS {
        unreachable; // no unowned allocation may escape
    }
    let p: PAddr = heap_alloc_raw(h, size, align);
    heap_record_live(h, p, size);
    return p;
}

// Why a non-trapping allocation could not be satisfied.
pub enum HeapError {
    Exhausted, // no free block fit and the bump frontier is out of space
}

// Non-trapping core aligned allocator: returns Exhausted instead of
// trapping when the heap is full. This is the body shared by the infallible
// `heap_alloc_raw` (which traps) and the fallible `heap_try_alloc`.
fn heap_try_alloc_raw(h: *mut Heap, size: usize, align: usize) -> Result<PAddr, HeapError> {
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
                    // Carve [astart, aend) out of this block. Remove the slot (compacting
                    // the sorted array), then release the head gap [fstart, astart) and
                    // tail remainder [aend, fend) back (each coalesces/restores as needed).
                    fl_take_at(h, i);
                    if pa_lt(fstart, astart) {
                        heap_release(h, fstart, pa_diff(fstart, astart));
                    }
                    if pa_lt(aend, fend) {
                        heap_release(h, aend, pa_diff(aend, fend));
                    }
                    return ok(astart);
                }
            }
        }
        i = i + 1;
    }

    // No free block fit: carve from the bump frontier.
    let start: PAddr = pa_align_up(h.next, align);
    let next: PAddr = pa_offset(start, size); // checked: traps on overflow
    if pa_lt(pr_end(&h.range), next) {
        return err(.Exhausted); // heap exhausted — caller decides (trap or recover)
    }
    // The alignment gap [h.next, start) is unused tail; once we advance past it, it
    // can never be reached by the frontier again, so return it to the free list.
    if pa_lt(h.next, start) {
        let gap: usize = pa_diff(h.next, start);
        let gstart: PAddr = h.next;
        h.next = next;
        heap_release(h, gstart, gap);
        return ok(start);
    }
    h.next = next;
    return ok(start);
}

// Core aligned allocator: traps on
// exhaustion, for the infallible callers that treat OOM as a kernel bug.
fn heap_alloc_raw(h: *mut Heap, size: usize, align: usize) -> PAddr {
    switch heap_try_alloc_raw(h, size, align) {
        ok(p) => { return p; }
        err(e) => { unreachable; } // heap exhausted on an infallible path
    }
}

// Public non-trapping frame allocator. Used by validation paths that need heap
// exhaustion to surface as a typed error rather than a kernel trap.
#[may_sleep]
pub fn heap_try_alloc(h: *mut Heap, size: usize, align: usize) -> Result<PAddr, HeapError> {
    if h.track_live != 0 && size != 0 && h.live_count >= HEAP_LIVE_SLOTS {
        return err(.Exhausted);
    }
    switch heap_try_alloc_raw(h, size, align) {
        ok(p) => {
            heap_record_live(h, p, size);
            return ok(p);
        }
        err(e) => { return err(e); }
    }
}

// Return a block to the heap so a later `alloc` can reuse it. Validates the request
// (fail closed on a bogus free), then releases [addr, addr+size) to the free list,
// coalescing with adjacent free space. The signature matches the Allocator's free
// closure once `h` is captured.
pub fn heap_free(h: *mut Heap, addr: PAddr, size: usize) -> void {
    if size == 0 {
        return;
    }
    heap_take_live(h, addr, size);
    if !pr_contains(&h.range, addr) {
        unreachable; // freeing an address this heap never owned
    }
    if size > pr_len(&h.range) {
        unreachable; // nonsensical size
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

// Grow the block [addr, addr+old_len) to new_len IN PLACE — no copy — but ONLY when it is the topmost
// bump-frontier block (its end == h.next, i.e. nothing was allocated after it) and the backing range
// still has room. Returns true on success (h.next advanced to addr+new_len), false otherwise (the
// caller must fall back to allocate-copy-free). This keeps realloc fast for a topmost block inside a
// fixed arena. Shrink/equal (new_len <= old_len) is reported as success with no change — the block is
// already big enough; realloc's shrink path keeps the original block.
pub fn heap_try_grow_in_place(h: *mut Heap, addr: PAddr, old_len: usize, new_len: usize) -> bool {
    if new_len <= old_len {
        return true;
    }
    let end: PAddr = pa_offset(addr, old_len);
    if !pa_eq(end, h.next) {
        return false; // not the topmost frontier block — cannot extend without moving
    }
    let new_end: PAddr = pa_offset(addr, new_len); // checked: traps on overflow
    if pa_lt(pr_end(&h.range), new_end) {
        return false; // backing range too short
    }
    heap_resize_live(h, addr, old_len, new_len);
    h.next = new_end;
    return true;
}

// Bytes still available: the untouched tail plus everything on the free list.
pub fn heap_available(h: *mut Heap) -> usize {
    var total: usize = pa_diff(h.next, pr_end(&h.range));
    var i: usize = 0;
    while i < HEAP_FREE_SLOTS {
        total = total + h.free[i].len;
        i = i + 1;
    }
    return total;
}

// Bytes that could not be represented in the bounded free-list metadata.
// Production health policy treats any non-zero value as allocator degradation
// instead of silently reporting the heap as healthy.
pub fn heap_dropped_free_bytes(h: *mut Heap) -> usize {
    return h.dropped_free_bytes;
}

pub fn heap_live_allocations(h: *mut Heap) -> usize {
    return h.live_count;
}

// The heap conforms to the Allocator trait (std/alloc §32), so callers allocate against
// a `*mut dyn Allocator` without knowing it's a kernel heap. `heap_alloc`/`heap_free` are
// already (self, …) -> …, so the methods delegate directly.
impl Allocator for Heap {
    fn alloc(self: *mut Heap, size: usize, align: usize) -> PAddr {
        return heap_alloc(self, size, align);
    }
    fn free(self: *mut Heap, addr: PAddr, size: usize) -> void {
        heap_free(self, addr, size);
    }
}

// View this heap as a generic `*mut dyn Allocator` — the checked coercion synthesizes the
// shared rodata vtable; the heap itself is the trait object's data.
pub fn heap_allocator(h: *mut Heap) -> *mut dyn Allocator {
    return h;
}
