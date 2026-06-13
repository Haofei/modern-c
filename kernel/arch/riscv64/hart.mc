// kernel/arch/riscv64/hart — the boot hart as a linear typestate.
//
// A hart progresses Boot → TrapReady → IrqsOn, and each CSR-touching transition
// is the *only* place that step is legal: you cannot enable interrupts before the
// trap vector is installed, because `enable_interrupts` consumes a
// `Hart<TrapReady>` that only `install_trap_vector` can produce. The hart is a
// linear `move` value (one owner); transitions consume the old state token with
// `drop` and mint the next.

import "csr.mc";

// Phantom typestate markers.
struct Boot {}
struct TrapReady {}
struct IrqsOn {}

move struct Hart<State> {
    id: u32,
}

// Claim the boot hart (called once from the entry path).
export fn boot_hart(id: u32) -> Hart<Boot> {
    return .{ .id = id };
}

// Install the machine trap vector. Only a Boot hart can.
export fn install_trap_vector(h: Hart<Boot>, vector: usize) -> Hart<TrapReady> {
    let id: u32 = h.id;
    write_trap_vector(vector);
    unsafe { forget_unchecked(h); }
    return .{ .id = id };
}

// Enable interrupts — only once the trap vector is in place. Unmasks the timer
// source and sets the global enable, so a trap can now fire.
export fn enable_interrupts(h: Hart<TrapReady>) -> Hart<IrqsOn> {
    let id: u32 = h.id;
    enable_timer_interrupt();
    enable_interrupts_global();
    unsafe { forget_unchecked(h); }
    return .{ .id = id };
}

// Mask interrupts again, returning to the TrapReady state.
export fn disable_interrupts(h: Hart<IrqsOn>) -> Hart<TrapReady> {
    let id: u32 = h.id;
    disable_interrupts_global();
    unsafe { forget_unchecked(h); }
    return .{ .id = id };
}

// The hart id (borrow; works in any state — read-only access independent of the
// typestate parameter).
export fn hart_id(comptime State: type, h: *Hart<State>) -> u32 {
    return h.id;
}
