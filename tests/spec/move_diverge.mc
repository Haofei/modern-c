// SPEC: section=18.1
// SPEC: milestone=linear-move
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_RESOURCE_LEAK

// Regression coverage for the move checker's *aborting / unreachable* control-flow
// edges (section 18.1). A path that ends in `trap(...)`, `unreachable`, or a call to
// a `-> never` function does not exit the function normally: it halts the program (or
// is provably impossible), so it performs no cleanup and reaches no successor. Such a
// path is the `Unreachable` lattice state — it carries NO leak obligation, and it must
// not be merged into the post-branch join (which would otherwise raise a spurious
// E_MOVE_BRANCH_MISMATCH against the falling-through arm). These cases all USED to be
// rejected by the frontend analysis, which only understood `return`/`break`/`continue`.

move struct Handle { v: u32 }
fn acquire() -> Handle {
    return .{ .v = 1 };
}
fn release(h: Handle) -> u32 {
    let v: u32 = h.v;
    unsafe { forget_unchecked(h); }
    return v;
}
extern fn panicf() -> never;

// --- accepted: deeply nested returns, every path consumes exactly once ---
fn accept_nested_returns(a: bool, b: bool) -> u32 {
    let h: Handle = acquire();
    if a {
        if b { return release(h); }
        else { return release(h); }
    }
    return release(h);
}

// --- accepted: a branch consumes then aborts via `trap(...)`; the fall-through
//     consumes. The aborting branch must not be merged as a stale live set. ---
fn accept_consume_then_trap(cond: bool) -> u32 {
    let h: Handle = acquire();
    if cond {
        release(h);
        trap(.Assert);
    }
    return release(h);
}

// --- accepted: same, aborting via a call to a `-> never` function ---
fn accept_consume_then_never_call(cond: bool) -> u32 {
    let h: Handle = acquire();
    if cond {
        release(h);
        panicf();
    }
    return release(h);
}

// --- accepted: same, aborting via `unreachable` ---
fn accept_consume_then_unreachable(cond: bool) -> u32 {
    let h: Handle = acquire();
    if cond {
        release(h);
        unreachable;
    }
    return release(h);
}

// --- accepted: a live resource on a branch that aborts via `trap(...)` carries no
//     leak obligation — the program halts before any cleanup could run — while the
//     fall-through consumes it normally ---
fn accept_abort_carries_no_leak(cond: bool) -> u32 {
    let h: Handle = acquire();
    if cond {
        trap(.Assert); // h still live here; the aborting branch has no leak obligation
    }
    return release(h);
}

// --- accepted: `defer` cleanup reserves both resources, so neither leaks on the
//     aborting branch nor on the normal exit ---
fn accept_defer_covers_abort(cond: bool) -> u32 {
    let h1: Handle = acquire();
    defer release(h1);
    let h2: Handle = acquire();
    defer release(h2);
    if cond {
        trap(.Assert);
    }
    return 0;
}

// --- rejected: a deeply nested `return` that leaks h on one path (the abort edges
//     above must not mask a genuine normal-exit leak) ---
fn reject_nested_return_leak(a: bool, b: bool) -> u32 {
    // EXPECT_ERROR: E_RESOURCE_LEAK
    let h: Handle = acquire();
    if a {
        if b { return 0; }
    }
    return release(h);
}
