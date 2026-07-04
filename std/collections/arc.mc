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
import "std/alloc/alloc.mc";

// `value` is first (offset 0) so arc_get can mint a pointer straight from the
// block address — avoids taking `&blk.value` (which the escape analysis over-rejects).
pub struct ArcBlock<T> {
    value: T,
    count: atomic<u32>,
}

// The handle carries the `*mut dyn Allocator` it was allocated from (its provenance), so
// `arc_drop` frees the block through that exact allocator with no separate, possibly
// mismatched, allocator argument. Every clone copies the same provenance. The
// allocator must outlive every handle (it is borrowed, not owned).
pub move struct Arc<T> {
    block: PAddr,
    allocator: *mut dyn Allocator, // provenance: the allocator that minted `block`
}

// Allocate a new refcounted block holding `value`, with one owner.
pub fn arc_new(comptime T: type, a: *mut dyn Allocator, value: T) -> Arc<T> {
    let addr: PAddr = alloc_bytes(a, sizeof(ArcBlock<T>), alignof(ArcBlock<T>));
    let blk: *mut ArcBlock<T> = raw.ptr<ArcBlock<T>>(addr);
    blk.count.store(1, .release);
    blk.value = value;
    return .{ .block = addr, .allocator = a };
}

// Allocate a refcounted block with one owner but an *uninitialized* value — the caller
// fills it via `arc_get_mut` before cloning or publishing it.
pub fn arc_new_uninit(comptime T: type, a: *mut dyn Allocator) -> Arc<T> {
    let addr: PAddr = alloc_bytes(a, sizeof(ArcBlock<T>), alignof(ArcBlock<T>));
    let blk: *mut ArcBlock<T> = raw.ptr<ArcBlock<T>>(addr);
    blk.count.store(1, .release);
    return .{ .block = addr, .allocator = a };
}

// Add an owner: bump the count and return another handle to the same block, carrying
// the same allocator provenance.
pub fn arc_clone(comptime T: type, h: *Arc<T>) -> Arc<T> {
    let blk: *mut ArcBlock<T> = raw.ptr<ArcBlock<T>>(h.block);
    // Check the saturation cap *before* incrementing, so the count is never wrapped to a
    // bogus value. A plain `fetch_add` would write `0` for one instant when the previous
    // value was the maximum — corrupting the refcount before any overflow check could run.
    // This is the reviewer's CAS form (load, refuse at the cap, store the +1) specialized
    // to the kernel's current cooperative single-core model, where no concurrent clone can
    // slip between the load and the store. A genuinely SMP-safe version needs an atomic
    // compare-exchange retry loop; that lands with preemption/SMP, alongside the address-
    // space locking uaccess already defers to the same milestone.
    let cur: u32 = blk.count.load(.acquire);
    if cur == 0xFFFF_FFFF {
        unreachable; // refcount saturated — too many owners; never wrap the counter
    }
    blk.count.store(cur + 1, .release); // cur < max, so the checked add cannot overflow
    return .{ .block = h.block, .allocator = h.allocator };
}

// Borrow the shared value immutably (valid while any handle lives). `value` is at
// the block's base, so the typed pointer is the block address reinterpreted as T.
pub fn arc_get(comptime T: type, h: *Arc<T>) -> *const T {
    var p: *const T = raw.ptr<T>(0);
    unsafe {
        p = raw.ptr<T>(h.block);
    }
    return p;
}

// Borrow the value mutably while this is the unique Arc owner. UNSAFE: the uniqueness is only
// proven at the refcount check below — the language has no borrow analysis to stop a later
// `arc_clone` from aliasing the returned `*mut T`. Callers must be in an `unsafe` block and
// must not clone or publish the handle while the pointer is live (the checker enforces the
// unsafe context, not the no-aliasing rule).
pub fn arc_get_mut(comptime T: type, h: *Arc<T>) -> *mut T {
    let blk: *mut ArcBlock<T> = raw.ptr<ArcBlock<T>>(h.block);
    if blk.count.load(.acquire) != 1 {
        unreachable; // mutable access requires unique ownership
    }
    return raw.ptr<T>(h.block);
}

// The current owner count (for tests / debugging).
pub fn arc_count(comptime T: type, h: *Arc<T>) -> u32 {
    let blk: *mut ArcBlock<T> = raw.ptr<ArcBlock<T>>(h.block);
    return blk.count.load(.acquire);
}

// Drop an owner, consuming this handle. Frees the block iff it was the last owner;
// returns whether it freed. The block is reclaimed through the handle's own
// allocator provenance, so it can never be freed through the wrong allocator.
pub fn arc_drop(comptime T: type, h: Arc<T>) -> bool {
    let blk: *mut ArcBlock<T> = raw.ptr<ArcBlock<T>>(h.block);
    let prev: u32 = blk.count.fetch_sub(1, .acq_rel);
    var freed: bool = false;
    if prev == 1 {
        fence.acquire(); // synchronize with prior releases before freeing
        free_bytes(h.allocator, h.block, sizeof(ArcBlock<T>));
        freed = true;
    }
    unsafe { forget_unchecked(h); } // husk: the refcounted block was already freed above if last
    return freed;
}
