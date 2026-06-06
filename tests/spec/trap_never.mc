// SPEC: section=4,20,D.2
// SPEC: milestone=trap-never
// SPEC: phase=sema,mir
// SPEC: expect=pass,compile_error,inspect
// SPEC: check=trap-lowering,E_NEVER_RETURNS,E_NEVER_FALLTHROUGH,E_NEVER_STORAGE,E_INVALID_TRAP_KIND

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

fn reject_fallthrough_from_never() -> never {
    // EXPECT_ERROR: E_NEVER_FALLTHROUGH
    let code: u32 = 0;
}

// EXPECT_ERROR: E_NEVER_STORAGE
fn reject_never_parameter(value: never) -> void {
    return;
}

fn reject_never_local() -> void {
    // EXPECT_ERROR: E_NEVER_STORAGE
    let value: never = trap(.Assert);
}

fn reject_never_array_local() -> void {
    // EXPECT_ERROR: E_NEVER_STORAGE
    var values: [2]never = uninit;
}

fn reject_never_maybe_uninit_payload() -> void {
    // EXPECT_ERROR: E_NEVER_STORAGE
    var value: MaybeUninit<never> = uninit;
}

// EXPECT_ERROR: E_NEVER_STORAGE
fn reject_never_phys_ptr_payload(value: PhysPtr<never>) -> void {
    return;
}

// EXPECT_ERROR: E_NEVER_STORAGE
global reject_never_global: never = trap(.Assert);

fn reject_unknown_trap_kind() -> never {
    // EXPECT_ERROR: E_INVALID_TRAP_KIND
    return trap(.WouldBlock);
}

fn reject_missing_trap_kind() -> never {
    // EXPECT_ERROR: E_INVALID_TRAP_KIND
    return trap();
}

fn reject_non_literal_trap_kind() -> never {
    // EXPECT_ERROR: E_INVALID_TRAP_KIND
    return trap(0);
}

fn reject_extra_trap_kind_arg() -> never {
    // EXPECT_ERROR: E_INVALID_TRAP_KIND
    return trap(.Bounds, .Assert);
}
