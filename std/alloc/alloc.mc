// std/alloc — a type-erased allocator interface (the Zig pattern, realized with an MC
// `trait`; docs/spec/MC_0.7_Final_Design.md §32). The concrete allocator (a kernel Heap,
// page allocator, slab, …) is the trait object's `data`, so generic code — containers,
// owning handles, drivers — allocates against a `*mut dyn Allocator` without naming the
// backend, and without an implicit global heap: you pass the allocator in. A
// `*mut dyn Allocator` is one {data,vtable} fat pointer over a shared rodata vtable —
// where the old closure-pair handle carried two per-instance {code,env} closures. Each
// backend supplies an `impl Allocator for <Backend>` and an adapter that coerces it to
// `*mut dyn Allocator`, living with that backend (e.g. `heap_allocator` in kernel/core/heap).

import "std/addr.mc";

trait Allocator {
    // (size, align) -> address of the allocation. A power-of-two align.
    fn alloc(self: *mut Self, size: usize, align: usize) -> PAddr;
    // (address, size) -> void. A no-op for bump allocators that don't reclaim.
    fn free(self: *mut Self, addr: PAddr, size: usize) -> void;
}

// Allocate `size` bytes aligned to `align` from `a`. `*mut dyn Allocator`: one
// {data,vtable} fat pointer over a shared rodata vtable, replacing the former struct of
// two per-instance closures. Mutable because allocation advances the backend's state.
pub fn alloc_bytes(a: *mut dyn Allocator, size: usize, align: usize) -> PAddr {
    return a.alloc(size, align);
}

// Return an allocation of `size` bytes at `addr` to `a` (no-op for bump allocators).
pub fn free_bytes(a: *mut dyn Allocator, addr: PAddr, size: usize) -> void {
    a.free(addr, size);
}

// ----- typed, owned allocation: a linear handle to one T, leak-checked -----
//
// `Owned<T>` is a `move` handle to storage for one T. Because it is linear, a handle
// that is never freed/returned is a compile-time `E_RESOURCE_LEAK` — the
// allocate-then-forget bug Zig can only catch at runtime in debug mode. Access the
// storage via `own_addr` + `raw.load/store<T>`; end its life with `own_free`.
//
// The handle carries the `*Allocator` it was created from (its provenance), so
// `own_free` reclaims through that exact allocator — there is no separate allocator
// argument that could mismatch the one `create` used. The allocator must outlive
// the handle (it is borrowed, not owned).

pub move struct Owned<T> {
    addr: PAddr,
    allocator: *mut dyn Allocator, // provenance: the allocator that minted `addr`
}

// Allocate storage for one T from `a` (size/align via reflection on T).
pub fn create(comptime T: type, a: *mut dyn Allocator) -> Owned<T> {
    return .{ .addr = alloc_bytes(a, sizeof(T), alignof(T)), .allocator = a };
}

// The backing address — a borrow; does not consume the handle.
pub fn own_addr(comptime T: type, o: *Owned<T>) -> PAddr {
    return o.addr;
}

// Free the storage back to its originating allocator, consuming the linear handle
// (its end of life). The allocator is taken from the handle, so a resource can
// never be freed through the wrong owner.
pub fn own_free(comptime T: type, o: Owned<T>) -> void {
    free_bytes(o.allocator, o.addr, sizeof(T));
    unsafe { forget_unchecked(o); } // husk: the storage was already freed above
}
