// std/rwlock — a reader/writer lock (spec §28 planned extension), built on the fair ticket
// `Spinlock` (std/spinlock) plus an atomic reader count, so it needs no compare-exchange.
//
// Many readers may hold the lock at once; a writer is exclusive against both other writers and
// new readers. A reader holds the gate only briefly — long enough to bump the reader count —
// then runs concurrently with other readers. A writer takes the gate for its whole critical
// section (blocking new readers and other writers) and waits for the existing readers to drain.
// Zero-initialized storage is a valid unlocked lock.

import "std/sync/spinlock.mc";

struct RwLock {
    gate: Spinlock,       // serializes writers and reader-entry (the ticket lock)
    readers: atomic<u32>, // number of readers currently holding the lock
}

export fn rwlock_init(rw: *mut RwLock) -> void {
    spinlock_init(&rw.gate);
    rw.readers.store(0, .release);
}

// Acquire shared (read) access. Returns once registered as a reader; blocks only while a writer
// holds the gate.
export fn read_lock(rw: *mut RwLock) -> void {
    spin_lock(&rw.gate);                  // wait out any writer, then register
    rw.readers.fetch_add(1, .acq_rel);
    spin_unlock(&rw.gate);                // release so other readers run concurrently
}

export fn read_unlock(rw: *mut RwLock) -> void {
    rw.readers.fetch_sub(1, .acq_rel);
}

// Acquire exclusive (write) access: take the gate (excluding writers and new readers), then
// wait for the readers that were already inside to finish.
export fn write_lock(rw: *mut RwLock) -> void {
    spin_lock(&rw.gate);
    var draining: bool = true;
    while draining {
        if rw.readers.load(.acquire) == 0 {
            draining = false;
        }
    }
}

export fn write_unlock(rw: *mut RwLock) -> void {
    spin_unlock(&rw.gate);
}

// The number of readers currently holding the lock (diagnostic / test use).
export fn rwlock_readers(rw: *mut RwLock) -> u32 {
    return rw.readers.load(.acquire);
}
