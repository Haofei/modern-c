// SPEC: section=25,D.1
// SPEC: milestone=name-resolution
// SPEC: phase=sema
// SPEC: expect=compile_error
// SPEC: check=E_UNKNOWN_IDENTIFIER,E_UNKNOWN_FUNCTION,E_UNKNOWN_TYPE,E_GENERIC_TYPE_ARG_COUNT

fn known_value() -> u32 {
    return 1;
}

fn reject_unknown_identifier() -> u32 {
    // EXPECT_ERROR: E_UNKNOWN_IDENTIFIER
    return missing_value;
}

fn reject_unknown_call() -> u32 {
    // EXPECT_ERROR: E_UNKNOWN_FUNCTION
    return missing_function();
}

fn reject_unknown_assignment_target(value: u32) -> void {
    // EXPECT_ERROR: E_UNKNOWN_IDENTIFIER
    missing_target = value;
}

// EXPECT_ERROR: E_UNKNOWN_TYPE
global reject_unknown_global_type: MissingType = 0;

// EXPECT_ERROR: E_UNKNOWN_TYPE
global reject_unknown_global_generic_type: MissingGeneric<u32> = 0;

// EXPECT_ERROR: E_UNKNOWN_TYPE
fn reject_unknown_param_type(value: MissingType) -> void {
    return;
}

// EXPECT_ERROR: E_UNKNOWN_TYPE
fn reject_unknown_generic_param_type(value: MissingGeneric<u32>) -> void {
    return;
}

// EXPECT_ERROR: E_UNKNOWN_TYPE
fn reject_unknown_return_type() -> MissingType {
    return trap(.Assert);
}

// EXPECT_ERROR: E_UNKNOWN_TYPE
fn reject_unknown_generic_return_type() -> MissingGeneric<u32> {
    return trap(.Assert);
}

fn reject_unknown_local_type() -> void {
    // EXPECT_ERROR: E_UNKNOWN_TYPE
    let value: MissingType = trap(.Assert);
}

fn reject_unknown_generic_local_type() -> void {
    // EXPECT_ERROR: E_UNKNOWN_TYPE
    let value: MissingGeneric<u32> = trap(.Assert);
}

// EXPECT_ERROR: E_UNKNOWN_TYPE
fn reject_unknown_pointer_pointee(value: *mut MissingType) -> void {
    return;
}

// EXPECT_ERROR: E_GENERIC_TYPE_ARG_COUNT
fn reject_result_type_missing_arg(value: Result<u32>) -> void {
    return;
}

// EXPECT_ERROR: E_GENERIC_TYPE_ARG_COUNT
fn reject_result_type_extra_arg(value: Result<u32, Error, u8>) -> void {
    return;
}

// EXPECT_ERROR: E_GENERIC_TYPE_ARG_COUNT
fn reject_user_ptr_type_extra_arg(value: UserPtr<u8, .extra>) -> void {
    return;
}

// EXPECT_ERROR: E_GENERIC_TYPE_ARG_COUNT
fn reject_wrap_type_missing_arg(value: wrap<>) -> void {
    return;
}

extern mmio struct RejectRegTypeMissingArg {
    // EXPECT_ERROR: E_GENERIC_TYPE_ARG_COUNT
    status: Reg<u8>,
}
