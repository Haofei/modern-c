// SPEC: section=18.1
// SPEC: milestone=linear-move
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_USE_AFTER_MOVE,E_CALL_ARG_COUNT,E_DROP_LINEAR_RESOURCE

// `forget_unchecked(x)` discards a linear `move` value without running any release —
// the right primitive for retiring a pure typestate token (which owns no resource), or
// for the tail of a destructor / transfer API. Plain `drop(x)` is NOT allowed on a
// linear value: it frees nothing, so it would silently leak a real resource.

move struct Boot { hartid: u32 }
move struct TrapReady { hartid: u32 }

extern fn boot_hart(id: u32) -> Boot;

// Accepted: retire the old typestate token (it owns nothing), return the new state.
fn install_trap_vector(h: Boot) -> TrapReady {
    let id: u32 = h.hartid;  // borrow before consuming
    forget_unchecked(h);     // retire the Boot token (no resource to free)
    return .{ .hartid = id };
}

fn accept_chain(id: u32) -> u32 {
    let b: Boot = boot_hart(id);
    let t: TrapReady = install_trap_vector(b);
    let final_id: u32 = t.hartid;
    forget_unchecked(t);
    return final_id;
}

// Rejected: using a value after it was forgotten.
fn reject_use_after_forget(id: u32) -> u32 {
    let b: Boot = boot_hart(id);
    forget_unchecked(b);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return b.hartid;
}

// Rejected: forget_unchecked takes exactly one argument.
fn reject_forget_arity(id: u32) -> void {
    let b: Boot = boot_hart(id);
    // EXPECT_ERROR: E_CALL_ARG_COUNT
    forget_unchecked(b, id);
}

// Rejected: `drop` on a linear value frees nothing — use a release fn or forget_unchecked.
fn reject_drop_resource(id: u32) -> void {
    let b: Boot = boot_hart(id);
    // EXPECT_ERROR: E_DROP_LINEAR_RESOURCE
    drop(b);
}
