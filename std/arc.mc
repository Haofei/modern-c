// std/arc — atomic reference counting: shared ownership with deterministic cleanup.
//
// `Arc<T>` is a linear `move` handle to a refcounted block allocated from an
// `Allocator`. Each handle is `move`, so the compiler forces every handle to be
// `arc_clone`d or `arc_drop`ped exactly once — the refcount can't drift by a forgotten
// handle (a guarantee Rust's Arc lacks). The block is freed when the last handle is
// dropped. Shared access is immutable; mutable access requires a unique owner
// (`arc_get_mut`, count == 1). Use Arc + std/sync for shared mutation. Reference
// cycles are not collected (use a non-owning handle to break them).

import "std/addr.mc";
import "std/alloc.mc";

// `value` is first (offset 0) so arc_get can mint a pointer straight from the
// block address — avoids taking `&blk.value` (which the escape analysis over-rejects).
struct ArcBlock<T> {
    value: T,
    count: atomic<u32>,
}

// The handle carries the `*Allocator` it was allocated from (its provenance), so
// `arc_drop` frees the block through that exact allocator with no separate, possibly
// mismatched, allocator argument. Every clone copies the same provenance. The
// allocator must outlive every handle (it is borrowed, not owned).
move struct Arc<T> {
    block: PAddr,
    allocator: *Allocator, // provenance: the allocator that minted `block`
}

// Allocate a new refcounted block holding `value`, with one owner.
export fn arc_new(comptime T: type, a: *Allocator, value: T) -> Arc<T> {
    let addr: PAddr = alloc_bytes(a, sizeof(ArcBlock<T>), alignof(ArcBlock<T>));
    let blk: *mut ArcBlock<T> = raw.ptr<ArcBlock<T>>(addr);
    blk.count.store(1, .release);
    blk.value = value;
    return .{ .block = addr, .allocator = a };
}

// Allocate a refcounted block with one owner but an *uninitialized* value — the caller
// fills it via `arc_get_mut` before cloning or publishing it.
export fn arc_new_uninit(comptime T: type, a: *Allocator) -> Arc<T> {
    let addr: PAddr = alloc_bytes(a, sizeof(ArcBlock<T>), alignof(ArcBlock<T>));
    let blk: *mut ArcBlock<T> = raw.ptr<ArcBlock<T>>(addr);
    blk.count.store(1, .release);
    return .{ .block = addr, .allocator = a };
}

// Add an owner: bump the count and return another handle to the same block, carrying
// the same allocator provenance.
export fn arc_clone(comptime T: type, h: *Arc<T>) -> Arc<T> {
    let blk: *mut ArcBlock<T> = raw.ptr<ArcBlock<T>>(h.block);
    // Take a ref with a single atomic read-modify-write, then inspect the value it
    // returned (the count *before* the add). A separate `load` then `fetch_add` is racy:
    // two clones near the cap can both pass the load and then both overflow. `fetch_add`
    // is one indivisible step, so checking its returned previous value detects an
    // overflow that no concurrent clone can have slipped past.
    let prev: u32 = blk.count.fetch_add(1, .acq_rel);
    if prev == 0xFFFF_FFFF {
        unreachable; // refcount overflow — the add wrapped past the maximum
    }
    return .{ .block = h.block, .allocator = h.allocator };
}

// Borrow the shared value immutably (valid while any handle lives). `value` is at
// the block's base, so the typed pointer is the block address reinterpreted as T.
export fn arc_get(comptime T: type, h: *Arc<T>) -> *const T {
    var p: *const T = raw.ptr<T>(0);
    unsafe {
        p = raw.ptr<T>(h.block);
    }
    return p;
}

// Borrow the value mutably only while this is the unique Arc owner.
export fn arc_get_mut(comptime T: type, h: *Arc<T>) -> *mut T {
    let blk: *mut ArcBlock<T> = raw.ptr<ArcBlock<T>>(h.block);
    if blk.count.load(.acquire) != 1 {
        unreachable; // mutable access requires unique ownership
    }
    return raw.ptr<T>(h.block);
}

// The current owner count (for tests / debugging).
export fn arc_count(comptime T: type, h: *Arc<T>) -> u32 {
    let blk: *mut ArcBlock<T> = raw.ptr<ArcBlock<T>>(h.block);
    return blk.count.load(.acquire);
}

// Drop an owner, consuming this handle. Frees the block iff it was the last owner;
// returns whether it freed. The block is reclaimed through the handle's own
// allocator provenance, so it can never be freed through the wrong allocator.
export fn arc_drop(comptime T: type, h: Arc<T>) -> bool {
    let blk: *mut ArcBlock<T> = raw.ptr<ArcBlock<T>>(h.block);
    let prev: u32 = blk.count.fetch_sub(1, .acq_rel);
    var freed: bool = false;
    if prev == 1 {
        fence.acquire(); // synchronize with prior releases before freeing
        free_bytes(h.allocator, h.block, sizeof(ArcBlock<T>));
        freed = true;
    }
    drop(h); // consume the linear handle
    return freed;
}
