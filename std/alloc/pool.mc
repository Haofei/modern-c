// std/pool — a fixed-capacity object pool with per-slot generations. Unlike the arena
// (bulk reset), a pool frees individual objects; the per-slot generation makes
// use-after-free and double-free fail closed at runtime (StaleHandle), the
// generational-slotmap pattern. Handles (PoolRef) are copyable; safety is the gen check
// at access, not linearity — complementary to the `move` resources, which give
// compile-time single-ownership but can't be shared.
//
// Capacity is a const-generic parameter: `Pool<T, N>` holds up to N objects of type T.

import "std/math.mc";

struct Pool<T, N> {
    slots: [N]T,
    gen: [N]u32, // current generation of each slot
    used: [N]bool,
    initialized: [N]bool,
    count: usize,
}

// Opaque (section 31): a PoolRef can only be minted and inspected by its own associated
// functions below, so outside code cannot forge one with a chosen slot/generation by raw
// field construction — the generational use-after-free protection rests on that.
opaque struct PoolRef<T> {
    index: usize,
    gen: u32,
}

impl PoolRef {
    fn mk(comptime T: type, index: usize, gen: u32) -> PoolRef<T> {
        return .{ .index = index, .gen = gen };
    }
    fn slot(comptime T: type, r: PoolRef<T>) -> usize {
        return r.index;
    }
    fn generation(comptime T: type, r: PoolRef<T>) -> u32 {
        return r.gen;
    }
}

enum PoolError {
    Full,
    StaleHandle, // the slot was freed (or freed + reused) since this handle was issued
    Uninitialized, // the slot is reserved but has not been written yet
}

export fn pool_init(comptime T: type, comptime N: usize, p: *mut Pool<T, N>) -> void {
    var i: usize = 0;
    while i < N {
        p.used[i] = false;
        p.initialized[i] = false;
        p.gen[i] = 0;
        i = i + 1;
    }
    p.count = 0;
}

// Reserve a free slot; the handle records the slot's current generation.
export fn pool_alloc(comptime T: type, comptime N: usize, p: *mut Pool<T, N>) -> Result<PoolRef<T>, PoolError> {
    var i: usize = 0;
    while i < N {
        if !p.used[i] {
            p.used[i] = true;
            p.initialized[i] = false;
            p.count = p.count + 1;
            return ok(PoolRef.mk(T, i, p.gen[i]));
        }
        i = i + 1;
    }
    return err(.Full);
}

// Free a slot, bumping its generation so outstanding handles become stale. A handle to
// an already-free slot (double free) or a stale generation is StaleHandle.
export fn pool_free(comptime T: type, comptime N: usize, p: *mut Pool<T, N>, r: PoolRef<T>) -> Result<bool, PoolError> {
    let index: usize = PoolRef.slot(T, r);
    let gen: u32 = PoolRef.generation(T, r);
    if index >= N {
        return err(.StaleHandle);
    }
    if !p.used[index] {
        return err(.StaleHandle); // double free
    }
    if p.gen[index] != gen {
        return err(.StaleHandle); // stale handle
    }
    p.used[index] = false;
    p.initialized[index] = false;
    // Checked increment so the slot generation fails closed (traps) on exhaustion rather
    // than wrapping back to a value a stale handle could match — a freed slot must never be
    // revived by an old PoolRef after 2^32 reuses. Same discipline as std/arena and std/grant.
    p.gen[index] = p.gen[index] + 1;
    p.count = p.count - 1;
    return ok(true);
}

// Store a value into the slot behind a live handle (use-after-free caught here).
export fn pool_set(comptime T: type, comptime N: usize, p: *mut Pool<T, N>, r: PoolRef<T>, value: T) -> Result<bool, PoolError> {
    let index: usize = PoolRef.slot(T, r);
    let gen: u32 = PoolRef.generation(T, r);
    if index >= N {
        return err(.StaleHandle);
    }
    if !p.used[index] {
        return err(.StaleHandle);
    }
    if p.gen[index] != gen {
        return err(.StaleHandle);
    }
    p.slots[index] = value;
    p.initialized[index] = true;
    return ok(true);
}

// Load the value behind a live handle, or StaleHandle if freed / reused.
export fn pool_load(comptime T: type, comptime N: usize, p: *mut Pool<T, N>, r: PoolRef<T>) -> Result<T, PoolError> {
    let index: usize = PoolRef.slot(T, r);
    let gen: u32 = PoolRef.generation(T, r);
    if index >= N {
        return err(.StaleHandle);
    }
    if !p.used[index] {
        return err(.StaleHandle);
    }
    if p.gen[index] != gen {
        return err(.StaleHandle);
    }
    if !p.initialized[index] {
        return err(.Uninitialized);
    }
    return ok(p.slots[index]);
}
