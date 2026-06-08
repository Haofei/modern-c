// std/arc — atomic reference counting: shared ownership with deterministic cleanup.
//
// `Arc<T>` is a linear `move` handle to a refcounted block allocated from an
// `Allocator`. Each handle is `move`, so the compiler forces every handle to be
// `arc_clone`d or `arc_drop`ped exactly once — the refcount can't drift by a forgotten
// handle (a guarantee Rust's Arc lacks). The block is freed when the last handle is
// dropped. Shared access is immutable-by-convention (use Arc + std/sync for shared
// mutation); reference cycles are not collected (use a non-owning handle to break them).

import "std/addr.mc";
import "std/alloc.mc";

// `value` is first (offset 0) so arc_get can mint a `*mut T` straight from the block
// address — avoids taking `&blk.value` (which the escape analysis over-rejects).
struct ArcBlock<T> {
    value: T,
    count: atomic<u32>,
}

move struct Arc<T> {
    block: PAddr,
}

// Block storage: `value` (size sizeof(T)) + the u32 count + padding. We over-allocate
// `sizeof(T) + 16` at 16-byte alignment rather than `sizeof(ArcBlock<T>)`, because
// reflection on a generic type inside a generic body isn't monomorphized yet; the
// `raw.ptr` cast still uses ArcBlock<T>'s real C field offsets, so this is sound.
const ARC_HEADER: usize = 16;

// Allocate a new refcounted block holding `value`, with one owner.
export fn arc_new(comptime T: type, a: *Allocator, value: T) -> Arc<T> {
    let addr: PAddr = alloc_bytes(a, sizeof(T) + ARC_HEADER, ARC_HEADER);
    let blk: *mut ArcBlock<T> = raw.ptr<ArcBlock<T>>(addr);
    blk.count.store(1, .release);
    blk.value = value;
    return .{ .block = addr };
}

// Allocate a refcounted block with one owner but an *uninitialized* value — the caller
// fills it via `arc_get` (the natural form for buffers populated after allocation).
export fn arc_new_uninit(comptime T: type, a: *Allocator) -> Arc<T> {
    let addr: PAddr = alloc_bytes(a, sizeof(T) + ARC_HEADER, ARC_HEADER);
    let blk: *mut ArcBlock<T> = raw.ptr<ArcBlock<T>>(addr);
    blk.count.store(1, .release);
    return .{ .block = addr };
}

// Add an owner: bump the count and return another handle to the same block.
export fn arc_clone(comptime T: type, h: *Arc<T>) -> Arc<T> {
    let blk: *mut ArcBlock<T> = raw.ptr<ArcBlock<T>>(h.block);
    blk.count.fetch_add(1, .acq_rel);
    return .{ .block = h.block };
}

// Borrow the shared value (valid while any handle lives). `value` is at the block's
// base, so the typed pointer is the block address reinterpreted as `*mut T`.
export fn arc_get(comptime T: type, h: *Arc<T>) -> *mut T {
    return raw.ptr<T>(h.block);
}

// The current owner count (for tests / debugging).
export fn arc_count(comptime T: type, h: *Arc<T>) -> u32 {
    let blk: *mut ArcBlock<T> = raw.ptr<ArcBlock<T>>(h.block);
    return blk.count.load(.acquire);
}

// Drop an owner, consuming this handle. Frees the block iff it was the last owner;
// returns whether it freed.
export fn arc_drop(comptime T: type, a: *Allocator, h: Arc<T>) -> bool {
    let blk: *mut ArcBlock<T> = raw.ptr<ArcBlock<T>>(h.block);
    let prev: u32 = blk.count.fetch_sub(1, .acq_rel);
    var freed: bool = false;
    if prev == 1 {
        fence.acquire(); // synchronize with prior releases before freeing
        free_bytes(a, h.block, sizeof(T) + ARC_HEADER);
        freed = true;
    }
    drop(h); // consume the linear handle
    return freed;
}
