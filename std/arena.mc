// std/arena — a bump arena over a caller-owned physical region, as a linear `move`
// resource. The arena hands out byte ranges; `reset` reclaims them all at once (the
// "allocate a batch, free together" pattern). Because `Arena` is `move`, forgetting
// to `arena_destroy` it is a compile-time `E_RESOURCE_LEAK` — the arena itself can't
// leak. Individual allocations are plain addresses (borrows of the arena); their
// use-after-reset safety is provided by the generational handles below (resolve
// checks the generation `reset` bumps).

import "std/addr.mc";
import "std/alloc.mc";
import "std/math.mc";

move struct Arena {
    base: PAddr,
    next: PAddr, // bump frontier
    end: PAddr,
    gen: u32, // bumped on every reset; stamped into GenRef handles
}

// Build an arena over a physical region (e.g. a frame range reserved at boot). The
// region is caller-owned; the arena borrows it and reclaims via reset, not free.
export fn arena_init(region: PhysRange) -> Arena {
    let start: PAddr = pr_start(&region);
    return .{ .base = start, .next = start, .end = pr_end(&region), .gen = 0 };
}

// Bump `size` bytes aligned to `align` (a power of two). Traps if exhausted. Borrows
// the arena (does not consume it).
export fn arena_alloc(a: *mut Arena, size: usize, align: usize) -> PAddr {
    let start: PAddr = pa_align_up(a.next, align);
    let next: PAddr = pa_offset(start, size); // checked: traps on overflow
    if pa_lt(a.end, next) {
        unreachable; // arena exhausted
    }
    a.next = next;
    return start;
}

// Reclaim every allocation at once and invalidate outstanding generational handles.
export fn arena_reset(a: *mut Arena) -> void {
    a.next = a.base;
    a.gen = wrapping_add_u32(a.gen, 1);
}

// Bytes still available between the bump frontier and the end of the region.
export fn arena_available(a: *mut Arena) -> usize {
    return pa_diff(a.next, a.end);
}

// Consume the linear arena (its end of life). The backing region is the caller's; we
// only need to consume `a` so the move checker is satisfied (no leak).
export fn arena_destroy(a: Arena) -> void {
    drop(a); // consume the linear arena (the backing region is the caller's)
}

// The arena's no-op free for the Allocator interface (it reclaims via reset). Validates
// the request so it fails closed on a bogus address/size — and so its params are used.
fn arena_free_noop(a: *mut Arena, addr: PAddr, size: usize) -> void {
    if pa_lt(addr, a.base) {
        unreachable; // address below the arena
    }
    if pa_lt(a.end, addr) {
        unreachable; // address past the arena
    }
    // The freed range must lie fully within the arena: addr + size <= end. Checked as
    // `size > end - addr` (overflow-safe, addr <= end established above) so a bogus subrange
    // that starts inside the arena but runs past its end is rejected, not just an oversized one.
    if size > pa_diff(addr, a.end) {
        unreachable; // range extends past the arena end
    }
}

// View the arena as a generic Allocator (std/alloc): alloc bumps, free is a no-op.
export fn arena_allocator(a: *mut Arena) -> Allocator {
    return .{
        .alloc = bind(a, arena_alloc),
        .free = bind(a, arena_free_noop),
    };
}

// ----- generational handles: runtime use-after-reset detection without lifetimes ----
//
// A GenRef is a *copyable* handle (not a move value) stamped with the arena's
// generation at allocation time. `arena_reset` bumps the generation, so any handle
// from before the reset fails to `arena_resolve` (StaleHandle) — a fail-closed catch
// for use-after-reset that MC's move/linear pass (no lifetimes) can't provide. Hold a
// GenRef, not a raw PAddr, and resolve at each use.

struct GenRef<T> {
    addr: PAddr,
    gen: u32,
}

enum ArenaError {
    StaleHandle,  // the handle predates a reset — its memory may have been reused
    ForgedHandle, // the handle's address is outside the arena's allocated region
}

// Allocate `size` bytes (aligned to `align`) and return a generational handle for a T.
// `size`/`align` come from the concrete call site (e.g. sizeof(T)/alignof(T)).
export fn arena_alloc_gen(comptime T: type, a: *mut Arena, size: usize, align: usize) -> GenRef<T> {
    return .{ .addr = arena_alloc(a, size, align), .gen = a.gen };
}

// Resolve a handle to its address iff it belongs to the arena's current generation.
export fn arena_resolve(comptime T: type, a: *mut Arena, h: GenRef<T>) -> Result<PAddr, ArenaError> {
    if h.gen != a.gen {
        return err(.StaleHandle); // used after a reset — memory may have been reused
    }
    // Defence in depth: a resolved address must point into allocated space [base, next).
    // Without strict module privacy a GenRef is structurally forgeable, so a matching
    // generation alone is not enough — a forged handle with the current generation but a
    // bogus address must not resolve to memory outside the arena.
    if pa_lt(h.addr, a.base) {
        return err(.ForgedHandle); // below the arena base
    }
    if !pa_lt(h.addr, a.next) {
        return err(.ForgedHandle); // at or past the bump frontier — never allocated
    }
    return ok(h.addr);
}
