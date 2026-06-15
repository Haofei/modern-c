// kernel/lib/mutex — a sleeping (blocking) mutex (spec §28 planned extension).
//
// Unlike `std/sync`'s SpinLock (which busy-waits), a contended sleeping mutex enqueues the
// caller as a waiter and yields to the scheduler instead of spinning, so a long critical section
// does not burn a core. This module is the scheduler-independent CORE: the lock state, the owner,
// and a FIFO waiter queue with direct hand-off on unlock (fair, no thundering herd, no
// starvation). The actual park (yield the current task) and wake (mark a task runnable) are the
// kernel's scheduler/wait-queue hooks — `mutex_lock` returns `Blocked` so the caller knows to
// park, and `mutex_unlock` returns the task id to wake.

import "std/ring.mc";

const MTX_WAITERS: usize = 8;

enum LockOutcome {
    Acquired, // the lock was free; the caller now holds it
    Blocked,  // the lock was held; the caller is enqueued as a waiter and must park
}

enum MtxError {
    NotOwner, // unlock attempted by a task that does not hold the lock
}

struct Mutex {
    locked: bool,
    owner: u32,                       // holding task id (meaningful only while `locked`)
    waiters: Ring<u32, MTX_WAITERS>,  // FIFO of parked task ids waiting for the lock
}

export fn mutex_init(m: *mut Mutex) -> void {
    m.locked = false;
    m.owner = 0;
    ring_init(u32, MTX_WAITERS, &m.waiters);
}

export fn mutex_is_locked(m: *mut Mutex) -> bool {
    return m.locked;
}

export fn mutex_owner(m: *mut Mutex) -> u32 {
    return m.owner;
}

export fn mutex_waiters(m: *mut Mutex) -> usize {
    return ring_len(u32, MTX_WAITERS, &m.waiters);
}

// Non-blocking attempt: take the lock if free, returning whether it was acquired.
export fn mutex_try_lock(m: *mut Mutex, task: u32) -> bool {
    if m.locked {
        return false;
    }
    m.locked = true;
    m.owner = task;
    return true;
}

// Acquire the lock for `task`. If free, the caller holds it (Acquired). If held, the caller is
// enqueued as a waiter (Blocked) — the kernel then parks `task` until a later unlock hands the
// lock to it.
export fn mutex_lock(m: *mut Mutex, task: u32) -> LockOutcome {
    if !m.locked {
        m.locked = true;
        m.owner = task;
        return .Acquired;
    }
    let pushed: bool = ring_push(u32, MTX_WAITERS, &m.waiters, task);
    return .Blocked;
}

// Release the lock held by `task`. If there is a waiter, the lock is handed DIRECTLY to the
// FIFO-next waiter (ownership transferred without unlocking, so no other task can race in) and
// that waiter's id is returned for the kernel to wake — `ok(id)`. With no waiters the lock is
// released and `ok(0)` is returned. `NotOwner` if `task` does not hold the lock.
export fn mutex_unlock(m: *mut Mutex, task: u32) -> Result<u32, MtxError> {
    if !m.locked {
        return err(.NotOwner);
    }
    if m.owner != task {
        return err(.NotOwner);
    }
    if ring_is_empty(u32, MTX_WAITERS, &m.waiters) {
        m.locked = false;
        m.owner = 0;
        return ok(0); // nobody waiting; the lock is now free
    }
    let next: u32 = ring_pop(u32, MTX_WAITERS, &m.waiters);
    m.owner = next; // lock stays held, ownership transferred to the woken waiter
    return ok(next);
}
