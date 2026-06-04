// SPEC: section=13
// SPEC: milestone=enum-declarations
// SPEC: phase=parse,sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_DUPLICATE_ENUM_CASE,E_ENUM_REPR_NOT_INTEGER,E_UNKNOWN_ENUM_CASE,E_NO_IMPLICIT_CONVERSION,E_RETURN_TYPE_MISMATCH

enum OpenError {
    not_found,
    denied,
    bad_path,
}

global default_error: OpenError = .denied;
// EXPECT_ERROR: E_UNKNOWN_ENUM_CASE
global reject_unknown_global_error: OpenError = .missing;
// EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
global reject_integer_global_error: OpenError = 1;

fn takes_open_error(error: OpenError) -> void;

fn accept_enum_local_initializer() -> OpenError {
    let error: OpenError = .not_found;
    return error;
}

fn reject_unknown_enum_local_initializer() -> OpenError {
    // EXPECT_ERROR: E_UNKNOWN_ENUM_CASE
    let error: OpenError = .missing;
    return .denied;
}

fn reject_integer_enum_local_initializer() -> OpenError {
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    let error: OpenError = 1;
    return .denied;
}

fn accept_enum_return() -> OpenError {
    return .bad_path;
}

fn reject_unknown_enum_return() -> OpenError {
    // EXPECT_ERROR: E_UNKNOWN_ENUM_CASE
    return .missing;
}

fn reject_integer_enum_return() -> OpenError {
    // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
    return 1;
}

fn accept_enum_call_arg() -> void {
    takes_open_error(.denied);
}

fn reject_unknown_enum_call_arg() -> void {
    // EXPECT_ERROR: E_UNKNOWN_ENUM_CASE
    takes_open_error(.missing);
}

fn reject_integer_enum_call_arg() -> void {
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    takes_open_error(1);
}

fn accept_enum_assignment() -> OpenError {
    var error: OpenError = .not_found;
    error = .denied;
    return error;
}

fn reject_unknown_enum_assignment() -> OpenError {
    var error: OpenError = .not_found;
    // EXPECT_ERROR: E_UNKNOWN_ENUM_CASE
    error = .missing;
    return error;
}

fn reject_integer_enum_assignment() -> OpenError {
    var error: OpenError = .not_found;
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    error = 1;
    return error;
}

enum Irq: u8 {
    timer = 32,
    keyboard = 33,
}

open enum DeviceState: u8 {
    idle = 0,
    busy = 1,
    error = 2,
}

enum RejectDuplicateEnumCase: u8 {
    ready = 1,
    // EXPECT_ERROR: E_DUPLICATE_ENUM_CASE
    ready = 2,
}

// EXPECT_ERROR: E_ENUM_REPR_NOT_INTEGER
enum RejectBoolRepresentation: bool {
    yes = 1,
}

fn reject_unknown_enum_switch_case(error: OpenError) -> void {
    switch error {
        // EXPECT_ERROR: E_UNKNOWN_ENUM_CASE
        .missing => {},
        _ => {},
    }
}
