// SMP mutual-exclusion demo: every hart increments a *non-atomic* shared counter
// ITERS times while holding a ticket spinlock. With correct locking the final count
// is exactly harts * ITERS; a broken lock would lose updates to the race. A separate
// atomic tracks how many harts have finished. The lock's zero-initialized storage is
// already a valid unlocked lock, so no init barrier is needed.

import "std/sync/spinlock.mc";

const ITERS: u32 = 2000;

global g_lock: Spinlock;
global g_counter: u32 = 0;
global g_done: atomic<u32> = atomic.init(0);

// One hart's work: ITERS locked increments, then mark this hart finished.
export fn lock_worker() -> void {
    var i: u32 = 0;
    while i < ITERS {
        spin_lock(&g_lock);
        g_counter = g_counter + 1;
        spin_unlock(&g_lock);
        i = i + 1;
    }
    g_done.fetch_add(1, .acq_rel);
}

export fn lock_done_count() -> u32 {
    return g_done.load(.acquire);
}

export fn lock_counter() -> u32 {
    return g_counter;
}
