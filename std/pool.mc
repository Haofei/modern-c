// std/pool — a fixed-capacity object pool with per-slot generations. Unlike the arena
// (bulk reset), a pool frees individual objects; the per-slot generation makes
// use-after-free and double-free fail closed at runtime (StaleHandle), the
// generational-slotmap pattern. Handles (PoolRef) are copyable; safety is the gen
// check at `pool_get`, not linearity — complementary to the `move` resources, which
// give compile-time single-ownership but can't be shared.
//
// Capacity is a fixed 16 (generic over the element type). A `Pool<T, N>` with a
// caller-chosen capacity awaits const-generic struct parameters.

import "std/math.mc";

const POOL_CAP: usize = 16;

struct Pool<T> {
    slots: [16]T,
    gen: [16]u32,   // current generation of each slot
    used: [16]bool,
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

export fn pool_init(comptime T: type, p: *mut Pool<T>) -> void {
    var i: usize = 0;
    while i < POOL_CAP {
        p.used[i] = false;
        p.gen[i] = 0;
        i = i + 1;
    }
    p.count = 0;
}

// Reserve a free slot; the handle records the slot's current generation.
export fn pool_alloc(comptime T: type, p: *mut Pool<T>) -> Result<PoolRef<T>, PoolError> {
    var i: usize = 0;
    while i < POOL_CAP {
        if !p.used[i] {
            p.used[i] = true;
            p.count = p.count + 1;
            return ok(.{ .index = i, .gen = p.gen[i] });
        }
        i = i + 1;
    }
    return err(.Full);
}

// Free a slot, bumping its generation so outstanding handles become stale. A handle
// to an already-free slot (double free) or a stale generation is StaleHandle.
export fn pool_free(comptime T: type, p: *mut Pool<T>, r: PoolRef<T>) -> Result<bool, PoolError> {
    if r.index >= POOL_CAP {
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
export fn pool_set(comptime T: type, p: *mut Pool<T>, r: PoolRef<T>, value: T) -> Result<bool, PoolError> {
    if r.index >= POOL_CAP {
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
export fn pool_load(comptime T: type, p: *mut Pool<T>, r: PoolRef<T>) -> Result<T, PoolError> {
    if r.index >= POOL_CAP {
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
