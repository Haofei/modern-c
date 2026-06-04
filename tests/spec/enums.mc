// SPEC: section=13
// SPEC: milestone=enum-declarations
// SPEC: phase=parse,sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_DUPLICATE_ENUM_CASE,E_ENUM_REPR_NOT_INTEGER,E_UNKNOWN_ENUM_CASE,E_NO_IMPLICIT_CONVERSION,E_RETURN_TYPE_MISMATCH,E_CLOSED_ENUM_CONVERSION_REQUIRES_VALIDATION,E_ENUM_RAW_REQUIRES_OPEN_ENUM,E_CALL_ARG_COUNT

enum OpenError {
    not_found,
    denied,
    bad_path,
}

enum OtherError {
    denied,
}

global default_error: OpenError = .denied;
// EXPECT_ERROR: E_UNKNOWN_ENUM_CASE
global reject_unknown_global_error: OpenError = .missing;
// EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
global reject_integer_global_error: OpenError = 1;
global other_error: OtherError = .denied;
// EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
global reject_cross_enum_global: OpenError = other_error;

fn takes_open_error(error: OpenError) -> void;
fn returns_other_error() -> OtherError;

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

fn reject_cross_enum_local_initializer(other: OtherError) -> OpenError {
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    let error: OpenError = other;
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

fn reject_cross_enum_return(other: OtherError) -> OpenError {
    // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
    return other;
}

fn reject_enum_return_to_integer(error: OpenError) -> u32 {
    // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
    return error;
}

fn reject_enum_literal_return_to_integer() -> u32 {
    // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
    return .denied;
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

fn reject_cross_enum_call_arg(other: OtherError) -> void {
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    takes_open_error(other);
}

fn reject_direct_cross_enum_call_arg() -> void {
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    takes_open_error(returns_other_error());
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

fn reject_cross_enum_assignment(other: OtherError) -> OpenError {
    var error: OpenError = .not_found;
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    error = other;
    return error;
}

fn reject_enum_assignment_to_integer(error: OpenError) -> u32 {
    var value: u32 = 0;
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    value = error;
    return value;
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

fn accept_open_enum_integer_cast(value: u8) -> DeviceState {
    return value as DeviceState;
}

fn accept_open_enum_raw(state: DeviceState) -> u8 {
    return state.raw();
}

fn reject_open_enum_raw_arg_count(state: DeviceState) -> u8 {
    // EXPECT_ERROR: E_CALL_ARG_COUNT
    return state.raw(1);
}

fn reject_closed_enum_integer_cast(value: u8) -> Irq {
    // EXPECT_ERROR: E_CLOSED_ENUM_CONVERSION_REQUIRES_VALIDATION
    return value as Irq;
}

fn reject_closed_enum_integer_literal_cast() -> Irq {
    // EXPECT_ERROR: E_CLOSED_ENUM_CONVERSION_REQUIRES_VALIDATION
    return 32 as Irq;
}

fn reject_closed_enum_raw(irq: Irq) -> u8 {
    // EXPECT_ERROR: E_ENUM_RAW_REQUIRES_OPEN_ENUM
    return irq.raw();
}

fn reject_enum_cast_to_integer(irq: Irq) -> u8 {
    // EXPECT_ERROR: E_ENUM_RAW_REQUIRES_OPEN_ENUM
    return irq as u8;
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
