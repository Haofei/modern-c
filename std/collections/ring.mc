// MC standard library — `ring`: a generic, const-generic-capacity FIFO ring buffer.
// `Ring<T, N>` holds up to N elements of type T (capacity is a caller-chosen value type
// parameter, like `Pool<T, N>`). In-place mutating API — what kernel queue users want;
// it lets them stop hand-rolling head/tail/count/`% CAP` logic.
//
// `T` must be COPYABLE: `ring_front` returns the oldest element by value without
// removing it, which would duplicate a linear `move` owner. `Ring<MoveT, N>` does
// not type-check anyway — `slots: [N]T` of a `move` type is rejected at the struct
// definition (E_MOVE_ARRAY_UNSUPPORTED) — so hold linear resources behind a copyable
// handle (pointer, index, DmaAddr), not by value. (See §28.2.)

struct Ring<T, N> {
    slots: [N]T,
    head: usize, // next write index
    tail: usize, // next read index (oldest)
    count: usize,
}

// Reset `r` to empty in place. (A zero-initialized Ring is already empty; this is for
// reuse. Slots are never read while `count` bounds the live region.)
export fn ring_init(comptime T: type, comptime N: usize, r: *mut Ring<T, N>) -> void {
    r.head = 0;
    r.tail = 0;
    r.count = 0;
}

export fn ring_len(comptime T: type, comptime N: usize, r: *mut Ring<T, N>) -> usize {
    return r.count;
}
#[irq_context]
export fn ring_is_empty(comptime T: type, comptime N: usize, r: *mut Ring<T, N>) -> bool {
    return r.count == 0;
}
export fn ring_is_full(comptime T: type, comptime N: usize, r: *mut Ring<T, N>) -> bool {
    return r.count == N;
}

// Enqueue at the head; returns false (no-op) if the ring is full.
export fn ring_push(comptime T: type, comptime N: usize, r: *mut Ring<T, N>, x: T) -> bool {
    if r.count == N {
        return false;
    }
    r.slots[r.head] = x;
    r.head = (r.head + 1) % N;
    r.count = r.count + 1;
    return true;
}

// The oldest element without removing it. Traps if empty — check `ring_is_empty` first.
export fn ring_front(comptime T: type, comptime N: usize, r: *mut Ring<T, N>) -> T {
    if r.count == 0 {
        unreachable; // ring empty
    }
    return r.slots[r.tail];
}

// Dequeue the tail (oldest) in place. Traps if empty — check `ring_is_empty` first.
#[irq_context]
export fn ring_pop(comptime T: type, comptime N: usize, r: *mut Ring<T, N>) -> T {
    if r.count == 0 {
        unreachable; // ring empty
    }
    let x: T = r.slots[r.tail];
    r.tail = (r.tail + 1) % N;
    r.count = r.count - 1;
    return x;
}
