// SMP coordination: every hart atomically bumps a shared counter on arrival, and
// the boot hart waits until all have checked in. The cross-hart synchronization is
// a single global `atomic<u32>` (the interrupt/MP-safe cell) accessed with
// acquire/release ordering — no locks, no races.

global g_hart_count: atomic<u32> = atomic.init(0);

// A hart announces it is running; returns the new total that have arrived.
export fn smp_hart_arrive() -> u32 {
    let prev: u32 = g_hart_count.fetch_add(1, .acq_rel);
    return prev + 1;
}

// How many harts have arrived so far.
export fn smp_count() -> u32 {
    return g_hart_count.load(.acquire);
}
