// SPEC: section=4,20,D.2
// SPEC: milestone=trap-never
// SPEC: phase=sema,mir
// SPEC: expect=pass,compile_error,inspect
// SPEC: check=trap-lowering,E_NEVER_RETURNS

fn trap_as_value() -> u32 {
    // EXPECT: trap(.Bounds) has type never and coerces to the u32 return position.
    return trap(.Bounds);
}

fn unreachable_as_value() -> u32 {
    // EXPECT: unreachable has type never and lowers to trap(.Unreachable).
    return unreachable;
}

fn never_returns_by_trap() -> never {
    // EXPECT: returning a never expression is not a normal return from a never function.
    return trap(.Assert);
}

fn reject_empty_return_from_never() -> never {
    // EXPECT_ERROR: E_NEVER_RETURNS
    return;
}

fn reject_value_return_from_never() -> never {
    // EXPECT_ERROR: E_NEVER_RETURNS
    return 0;
}
