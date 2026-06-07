// MC standard library — `sync`: locks with linear `Guard`s (section 28.1), the
// second use of the linear `move` qualifier after DMA. Acquiring a lock yields a
// `move` (linear) guard; releasing consumes it. The compiler then rejects:
//   - forgetting to unlock          → E_RESOURCE_LEAK
//   - double-unlock / use-after     → E_USE_AFTER_MOVE
//   - touching the guard after release
//
// The acquire/release primitives are platform code (the bare-metal runtime or
// the host): a single-core kernel disables interrupts; an SMP kernel uses a
// ticket lock. `std/sync` supplies the typed, linear API over them.

struct SpinLock {
    state: u32,
}

// Held witnesses an acquired lock; releasing it consumes the witness.
move struct Guard {
    lock: *SpinLock,
}

// Like Guard, but also captures the saved interrupt state, so the critical
// section is provably interrupt-free and restores on release.
move struct IrqGuard {
    lock: *SpinLock,
    flags: usize,
}

extern fn mc_spin_acquire(l: *SpinLock) -> Guard;
extern fn mc_spin_release(g: Guard) -> void;
extern fn mc_spin_acquire_irqsave(l: *SpinLock) -> IrqGuard;
extern fn mc_spin_release_irqrestore(g: IrqGuard) -> void;

// Acquire `l`, returning the linear guard. Spins until acquired.
export fn lock(l: *SpinLock) -> Guard {
    return mc_spin_acquire(l);
}

// Release the lock by consuming its guard.
export fn unlock(g: Guard) -> void {
    mc_spin_release(g);
}

// IRQ-safe acquire: disables interrupts and returns a guard that re-enables them
// on release.
export fn lock_irqsave(l: *SpinLock) -> IrqGuard {
    return mc_spin_acquire_irqsave(l);
}

export fn unlock_irqrestore(g: IrqGuard) -> void {
    mc_spin_release_irqrestore(g);
}
