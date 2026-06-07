// MC standard library — `ring`: a generic fixed-capacity ring buffer
// (section 28.2), the producer/consumer queue a NIC's TX/RX descriptor paths
// use. `Ring<T>` is generic over the element type (section 22); capacity is a
// fixed 16 for v0 (a `comptime CAP` capacity awaits value type-parameters on
// generic structs). Slots typically hold descriptors carrying a `DmaAddr`.

struct Ring<T> {
    slots: [16]T,
    head: usize,  // next write index
    tail: usize,  // next read index
    count: usize,
}

// An empty ring; `zero` seeds the backing storage (uninitialized slots are never
// read while `count` bounds the live region).
fn empty(comptime T: type, zero: T) -> Ring<T> {
    return .{
        .slots = .{ zero, zero, zero, zero, zero, zero, zero, zero,
                    zero, zero, zero, zero, zero, zero, zero, zero },
        .head = 0,
        .tail = 0,
        .count = 0,
    };
}

fn is_empty(comptime T: type, r: Ring<T>) -> bool {
    return r.count == 0;
}

fn is_full(comptime T: type, r: Ring<T>) -> bool {
    return r.count == 16;
}

fn len(comptime T: type, r: Ring<T>) -> usize {
    return r.count;
}

// Enqueue `x` at the head, returning the updated ring (value semantics).
// Pushing a full ring traps (a producer must check `is_full` first).
fn push(comptime T: type, r: Ring<T>, x: T) -> Ring<T> {
    if r.count == 16 {
        unreachable; // ring full
    }
    var result: Ring<T> = r;
    result.slots[result.head] = x;
    result.head = (result.head + 1) % 16;
    result.count = result.count + 1;
    return result;
}

// The element at the tail (oldest), without removing it. Traps if empty.
fn front(comptime T: type, r: Ring<T>) -> T {
    if r.count == 0 {
        unreachable; // ring empty
    }
    return r.slots[r.tail];
}

// Remove the tail element, returning the updated ring. Traps if empty.
fn pop(comptime T: type, r: Ring<T>) -> Ring<T> {
    if r.count == 0 {
        unreachable; // ring empty
    }
    var result: Ring<T> = r;
    result.tail = (result.tail + 1) % 16;
    result.count = result.count - 1;
    return result;
}
