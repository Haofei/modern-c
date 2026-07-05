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

pub struct SpinLock {
    state: u32,
}

// Held witnesses an acquired lock; releasing it consumes the witness.
pub move struct Guard {
    lock: *SpinLock,
}

// Like Guard, but also captures the saved interrupt state, so the critical
// section is provably interrupt-free and restores on release.
pub move struct IrqGuard {
    lock: *SpinLock,
    flags: usize,
}

// The platform seam passes only pointers/scalars (extern fns must not pass or return
// structs by value — E_EXTERN_STRUCT_BY_VALUE, no C ABI classification yet). The linear
// Guard/IrqGuard witnesses are constructed and consumed on the MC side of the seam.
extern fn mc_spin_acquire(l: *SpinLock) -> void;
extern fn mc_spin_release(l: *SpinLock) -> void;
extern fn mc_spin_acquire_irqsave(l: *SpinLock) -> usize; // returns the saved irq flags
extern fn mc_spin_release_irqrestore(l: *SpinLock, flags: usize) -> void;

// Acquire `l`, returning the linear guard. Spins until acquired.
pub fn lock(l: *SpinLock) -> Guard {
    mc_spin_acquire(l);
    return .{ .lock = l };
}

// Release the lock by consuming its guard.
pub fn unlock(g: Guard) -> void {
    let l: *SpinLock = g.lock; // borrow before consuming
    unsafe { forget_unchecked(g); }
    mc_spin_release(l);
}

// IRQ-safe acquire: disables interrupts and returns a guard that re-enables them
// on release.
pub fn lock_irqsave(l: *SpinLock) -> IrqGuard {
    return .{ .lock = l, .flags = mc_spin_acquire_irqsave(l) };
}

pub fn unlock_irqrestore(g: IrqGuard) -> void {
    let l: *SpinLock = g.lock; // borrow before consuming
    let flags: usize = g.flags;
    unsafe { forget_unchecked(g); }
    mc_spin_release_irqrestore(l, flags);
}
