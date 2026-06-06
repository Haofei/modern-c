// SPEC: section=4
// SPEC: milestone=void-return
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_VOID_RETURNS_VALUE,E_VOID_STORAGE

fn accept_empty_return() -> void {
    // EXPECT: void functions may return no value.
    return;
}

fn accept_unit_return() -> void {
    // EXPECT: the unit expression has type void.
    return ();
}

fn accept_never_return_from_void() -> void {
    // EXPECT: never coerces to the void return position.
    return trap(.Assert);
}

fn reject_value_return_from_void() -> void {
    // EXPECT_ERROR: E_VOID_RETURNS_VALUE
    return 1;
}

fn reject_bool_return_from_void() -> void {
    // EXPECT_ERROR: E_VOID_RETURNS_VALUE
    return true;
}

// EXPECT_ERROR: E_VOID_STORAGE
fn reject_void_parameter(value: void) -> void {
    return;
}

fn reject_void_local() -> void {
    // EXPECT_ERROR: E_VOID_STORAGE
    let value: void = ();
}

fn reject_void_array_local() -> void {
    // EXPECT_ERROR: E_VOID_STORAGE
    var values: [2]void = uninit;
}

fn reject_void_maybe_uninit_payload() -> void {
    // EXPECT_ERROR: E_VOID_STORAGE
    var value: MaybeUninit<void> = uninit;
}

// EXPECT_ERROR: E_VOID_STORAGE
fn reject_void_user_ptr_payload(value: UserPtr<void>) -> void {
    return;
}

fn accept_result_void_marker() -> Result<void, Error> {
    return ok(());
}
