// std/canary — a lightweight stack-frame guard (D2.4, stack-overflow half).
//
// A function that wants overflow protection places a `StackGuard` at the top of its
// frame (the boundary a downward-growing overflow would smash first), then calls
// `guard_check` before it returns. The guard holds a known magic value; if a buffer
// that lives *below* the guard in the same frame is overrun upward — or a deeper
// callee runs off the end of the stack region into this frame — the magic is
// clobbered and `guard_check` traps (`unreachable`) instead of letting the corrupted
// frame return into an attacker-chosen address.
//
// This is the "lighter" canary the hardening item asks for: a known guard value near
// a frame boundary, checked at a defined point. It does not need paging. Real guard
// pages (an unmapped page below the stack that faults on touch) are the heavier,
// paging-dependent mechanism and are deferred.

// The canary magic. Non-trivial, non-zero, and not a plausible pointer/length, so an
// accidental zero-fill or small-int spill does not happen to reproduce it.
const STACK_CANARY: u64 = 0xC0DE_FACE_DEAD_BEEF;

// A guard word to embed at a frame boundary.
struct StackGuard {
    magic: u64,
}

// Arm a fresh guard with the canary magic. Place the returned value at the top of the
// frame (declare it before the buffers it protects).
export fn guard_new() -> StackGuard {
    return .{ .magic = STACK_CANARY };
}

// True iff the guard still holds the canary magic (no corruption).
export fn guard_ok(g: *StackGuard) -> bool {
    return g.magic == STACK_CANARY;
}

// Check a guard at a function's exit / a checkpoint. Traps the instant the canary has
// been overwritten — i.e. on a detected stack-frame overflow — rather than returning
// through a smashed frame.
export fn guard_check(g: *StackGuard) -> void {
    if g.magic != STACK_CANARY {
        unreachable; // stack canary corrupted: frame overflow detected
    }
}

// Test hook: deliberately smash a guard, the way an overflowing write would. Used by
// the demo to prove `guard_check` actually fires on corruption (vs. passing a clean
// guard). Not for production paths.
export fn guard_smash(g: *mut StackGuard) -> void {
    g.magic = 0;
}
