// SPEC: section=18.1
// SPEC: milestone=linear-move
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_USE_AFTER_MOVE,E_CALL_ARG_COUNT

// `drop(x)` consumes a linear `move` value, so a pure-MC typestate transition can
// retire the old state token without leaking it (and without an extern primitive).

move struct Boot { hartid: u32 }
move struct TrapReady { hartid: u32 }

extern fn boot_hart(id: u32) -> Boot;

// Accepted: consume the old state token, return the new state.
fn install_trap_vector(h: Boot) -> TrapReady {
    let id: u32 = h.hartid; // borrow before consuming
    drop(h);                // retire the Boot token
    return .{ .hartid = id };
}

fn accept_chain(id: u32) -> u32 {
    let b: Boot = boot_hart(id);
    let t: TrapReady = install_trap_vector(b);
    let final_id: u32 = t.hartid;
    drop(t);
    return final_id;
}

// Rejected: using a value after it was dropped.
fn reject_use_after_drop(id: u32) -> u32 {
    let b: Boot = boot_hart(id);
    drop(b);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return b.hartid;
}

// Rejected: drop takes exactly one argument.
fn reject_drop_arity(id: u32) -> void {
    let b: Boot = boot_hart(id);
    // EXPECT_ERROR: E_CALL_ARG_COUNT
    drop(b, id);
}
