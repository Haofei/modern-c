// MC standard library — `slotmap`: a fixed-capacity table of T with small-integer handles
// (the slot index). Allocate returns the lowest free index; get/set/free are bounds- and
// liveness-checked, so an out-of-range handle, or one whose slot is *currently* free,
// fails closed with BadHandle. This is the index-handle table the kernel hand-rolls
// everywhere (fd tables, mount tables, socket tables, ...).
//
// CONTRACT — the handle is a bare index, NOT generational. After a slot is freed AND
// reallocated, an old handle to that index becomes valid again and silently refers to the
// NEW occupant (the classic ABA problem). SlotMap therefore detects use-after-free only
// until the slot is reused, not across reuse. This matches POSIX fd semantics (a closed fd
// number is later reused) and is fine for that. If you need a handle that goes permanently
// invalid after free — detecting stale references across reuse — use `std/pool`, whose
// generation counter makes a reused slot reject the old handle.

pub struct SlotMap<T, N> {
    slots: [N]T,
    used: [N]bool,
    count: usize,
}

pub enum SlotError {
    Full,
    BadHandle, // out of range, or the slot is currently free (see the ABA note above)
}

pub fn slotmap_init(comptime T: type, comptime N: usize, m: *mut SlotMap<T, N>) -> void {
    var i: usize = 0;
    while i < N {
        m.used[i] = false;
        i = i + 1;
    }
    m.count = 0;
}

// Reserve the lowest free slot; returns its handle (index).
pub fn slotmap_alloc(comptime T: type, comptime N: usize, m: *mut SlotMap<T, N>) -> Result<usize, SlotError> {
    var i: usize = 0;
    while i < N {
        if !m.used[i] {
            m.used[i] = true;
            m.count = m.count + 1;
            return ok(i);
        }
        i = i + 1;
    }
    return err(.Full);
}

// Reserve a SPECIFIC slot by index — for rebuilding a table at fixed handles, e.g. fork fd
// inheritance, where the child must keep the parent's exact fd numbers (including gaps).
// BadHandle if the index is out of range; Full if that slot is already in use.
pub fn slotmap_alloc_at(comptime T: type, comptime N: usize, m: *mut SlotMap<T, N>, h: usize) -> Result<usize, SlotError> {
    if h >= N {
        return err(.BadHandle);
    }
    if m.used[h] {
        return err(.Full);
    }
    m.used[h] = true;
    m.count = m.count + 1;
    return ok(h);
}

pub fn slotmap_live(comptime T: type, comptime N: usize, m: *mut SlotMap<T, N>, h: usize) -> bool {
    if h >= N {
        return false;
    }
    return m.used[h];
}

// Store a value into a live slot.
pub fn slotmap_set(comptime T: type, comptime N: usize, m: *mut SlotMap<T, N>, h: usize, value: T) -> Result<bool, SlotError> {
    if !slotmap_live(T, N, m, h) {
        return err(.BadHandle);
    }
    m.slots[h] = value;
    return ok(true);
}

// Load the value behind a live handle (use-after-free caught here).
pub fn slotmap_get(comptime T: type, comptime N: usize, m: *mut SlotMap<T, N>, h: usize) -> Result<T, SlotError> {
    if !slotmap_live(T, N, m, h) {
        return err(.BadHandle);
    }
    return ok(m.slots[h]);
}

// Release a slot; the handle becomes BadHandle (double-free is also BadHandle).
pub fn slotmap_free(comptime T: type, comptime N: usize, m: *mut SlotMap<T, N>, h: usize) -> Result<bool, SlotError> {
    if !slotmap_live(T, N, m, h) {
        return err(.BadHandle);
    }
    m.used[h] = false;
    m.count = m.count - 1;
    return ok(true);
}

pub fn slotmap_count(comptime T: type, comptime N: usize, m: *mut SlotMap<T, N>) -> usize {
    return m.count;
}
