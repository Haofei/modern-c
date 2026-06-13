// std/alloc — a type-erased allocator handle (the Zig pattern, realized with MC
// closures). The concrete allocator (a kernel Heap, page allocator, slab, …) is
// *captured* by the alloc/free closures, so generic code — containers, owning
// closures, drivers — allocates against `*Allocator` without naming the backend, and
// without an implicit global heap: you pass the allocator in. Adapters that build an
// `Allocator` from a concrete allocator live with that allocator (e.g.
// `heap_allocator` in kernel/core/heap).

import "std/addr.mc";

struct Allocator {
    // (size, align) -> address of the allocation. A power-of-two align.
    alloc: closure(usize, usize) -> PAddr,
    // (address, size) -> void. A no-op for bump allocators that don't reclaim.
    free: closure(PAddr, usize) -> void,
}

// Allocate `size` bytes aligned to `align` from `a`.
export fn alloc_bytes(a: *Allocator, size: usize, align: usize) -> PAddr {
    let f: closure(usize, usize) -> PAddr = a.alloc;
    return f(size, align);
}

// Return an allocation of `size` bytes at `addr` to `a` (no-op for bump allocators).
export fn free_bytes(a: *Allocator, addr: PAddr, size: usize) -> void {
    let f: closure(PAddr, usize) -> void = a.free;
    f(addr, size);
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

move struct Owned<T> {
    addr: PAddr,
    allocator: *Allocator, // provenance: the allocator that minted `addr`
}

// Allocate storage for one T from `a` (size/align via reflection on T).
export fn create(comptime T: type, a: *Allocator) -> Owned<T> {
    return .{ .addr = alloc_bytes(a, sizeof(T), alignof(T)), .allocator = a };
}

// The backing address — a borrow; does not consume the handle.
export fn own_addr(comptime T: type, o: *Owned<T>) -> PAddr {
    return o.addr;
}

// Free the storage back to its originating allocator, consuming the linear handle
// (its end of life). The allocator is taken from the handle, so a resource can
// never be freed through the wrong owner.
export fn own_free(comptime T: type, o: Owned<T>) -> void {
    free_bytes(o.allocator, o.addr, sizeof(T));
    drop(o); // consume the linear handle
}
