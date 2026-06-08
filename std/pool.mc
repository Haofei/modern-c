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
    count: usize,
}

struct PoolRef<T> {
    index: usize,
    gen: u32,
}

enum PoolError {
    Full,
    StaleHandle, // the slot was freed (or freed + reused) since this handle was issued
}

export fn pool_init(comptime T: type, comptime N: usize, p: *mut Pool<T, N>) -> void {
    var i: usize = 0;
    while i < N {
        p.used[i] = false;
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
            p.count = p.count + 1;
            return ok(.{ .index = i, .gen = p.gen[i] });
        }
        i = i + 1;
    }
    return err(.Full);
}

// Free a slot, bumping its generation so outstanding handles become stale. A handle to
// an already-free slot (double free) or a stale generation is StaleHandle.
export fn pool_free(comptime T: type, comptime N: usize, p: *mut Pool<T, N>, r: PoolRef<T>) -> Result<bool, PoolError> {
    if r.index >= N {
        return err(.StaleHandle);
    }
    if !p.used[r.index] {
        return err(.StaleHandle); // double free
    }
    if p.gen[r.index] != r.gen {
        return err(.StaleHandle); // stale handle
    }
    p.used[r.index] = false;
    p.gen[r.index] = wrapping_add_u32(p.gen[r.index], 1);
    p.count = p.count - 1;
    return ok(true);
}

// Store a value into the slot behind a live handle (use-after-free caught here).
export fn pool_set(comptime T: type, comptime N: usize, p: *mut Pool<T, N>, r: PoolRef<T>, value: T) -> Result<bool, PoolError> {
    if r.index >= N {
        return err(.StaleHandle);
    }
    if !p.used[r.index] {
        return err(.StaleHandle);
    }
    if p.gen[r.index] != r.gen {
        return err(.StaleHandle);
    }
    p.slots[r.index] = value;
    return ok(true);
}

// Load the value behind a live handle, or StaleHandle if freed / reused.
export fn pool_load(comptime T: type, comptime N: usize, p: *mut Pool<T, N>, r: PoolRef<T>) -> Result<T, PoolError> {
    if r.index >= N {
        return err(.StaleHandle);
    }
    if !p.used[r.index] {
        return err(.StaleHandle);
    }
    if p.gen[r.index] != r.gen {
        return err(.StaleHandle);
    }
    return ok(p.slots[r.index]);
}
