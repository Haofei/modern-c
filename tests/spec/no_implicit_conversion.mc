// SPEC: section=3,5
// SPEC: milestone=no-implicit-conversion
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_NO_IMPLICIT_CONVERSION,E_INTEGER_LITERAL_OUT_OF_RANGE,E_SIGNED_UNSIGNED_MIX,E_NO_IMPLICIT_INTEGER_PROMOTION,E_ARITH_DOMAIN_UNSIGNED,E_OPERATOR_OPERAND

fn accept_context_typed_integer_literal() -> u32 {
    let x: u32 = 10;
    return x;
}

fn accept_u8_max_literal() -> u8 {
    let x: u8 = 255;
    return x;
}

fn accept_i8_max_literal() -> i8 {
    let x: i8 = 127;
    return x;
}

fn accept_i8_min_literal() -> i8 {
    let x: i8 = -128;
    return x;
}

fn accept_grouped_i8_min_literal() -> i8 {
    let x: i8 = (-128);
    return x;
}

fn accept_negative_hex_i8_min_literal() -> i8 {
    let x: i8 = -0x80;
    return x;
}

fn accept_hex_u8_max_literal() -> u8 {
    let x: u8 = 0xff;
    return x;
}

fn accept_same_width_local_initializer(a: u32) -> u32 {
    let x: u32 = a;
    return x;
}

fn accept_same_type_arithmetic(a: u32, b: u32) -> u32 {
    return a + b;
}

fn accept_context_typed_literal_arithmetic(a: u32) -> u32 {
    return a + 1;
}

fn accept_same_type_comparison(a: i32, b: i32) -> bool {
    return a < b;
}

fn reject_u8_out_of_range_literal() -> u8 {
    // EXPECT_ERROR: E_INTEGER_LITERAL_OUT_OF_RANGE
    let y: u8 = 256;
    return y;
}

fn reject_i8_out_of_range_literal() -> i8 {
    // EXPECT_ERROR: E_INTEGER_LITERAL_OUT_OF_RANGE
    let y: i8 = 128;
    return y;
}

fn reject_i8_below_range_literal() -> i8 {
    // EXPECT_ERROR: E_INTEGER_LITERAL_OUT_OF_RANGE
    let y: i8 = -129;
    return y;
}

fn reject_negative_hex_i8_out_of_range_literal() -> i8 {
    // EXPECT_ERROR: E_INTEGER_LITERAL_OUT_OF_RANGE
    let y: i8 = -0x81;
    return y;
}

fn reject_u8_negative_literal() -> u8 {
    // EXPECT_ERROR: E_INTEGER_LITERAL_OUT_OF_RANGE
    let y: u8 = -1;
    return y;
}

fn reject_hex_u8_out_of_range_literal() -> u8 {
    // EXPECT_ERROR: E_INTEGER_LITERAL_OUT_OF_RANGE
    let y: u8 = 0x100;
    return y;
}

fn reject_wrap_literal_requires_explicit_modulo() -> wrap<u8> {
    // EXPECT_ERROR: E_INTEGER_LITERAL_OUT_OF_RANGE
    let z: wrap<u8> = 300;
    return z;
}

fn reject_runtime_integer_widening(a: u32) -> u64 {
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    let widened: u64 = a;
    return widened;
}

fn reject_bool_from_integer(a: u32) -> bool {
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    let flag: bool = a;
    return flag;
}

fn reject_integer_from_bool(flag: bool) -> u32 {
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    let x: u32 = flag;
    return x;
}

fn reject_implicit_wrap_from_checked(a: u32) -> wrap<u32> {
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    let x: wrap<u32> = a;
    return x;
}

fn reject_signed_wrap_domain() -> void {
    // EXPECT_ERROR: E_ARITH_DOMAIN_UNSIGNED
    let x: wrap<i32> = 1;
}

fn reject_signed_sat_domain() -> void {
    // EXPECT_ERROR: E_ARITH_DOMAIN_UNSIGNED
    let x: sat<i16> = 1;
}

// EXPECT_ERROR: E_ARITH_DOMAIN_UNSIGNED
fn reject_signed_serial_domain(value: serial<i32>) -> void {
    return;
}

// EXPECT_ERROR: E_ARITH_DOMAIN_UNSIGNED
fn reject_bool_counter_domain(value: counter<bool>) -> void {
    return;
}

fn reject_signed_unsigned_arithmetic(a: i32, b: u32) -> i32 {
    // EXPECT_ERROR: E_SIGNED_UNSIGNED_MIX
    return a + b;
}

fn reject_unsigned_signed_comparison(a: u32, b: i32) -> bool {
    // EXPECT_ERROR: E_SIGNED_UNSIGNED_MIX
    return a < b;
}

fn reject_integer_width_arithmetic(a: u16, b: u32) -> u16 {
    // EXPECT_ERROR: E_NO_IMPLICIT_INTEGER_PROMOTION
    return a + b;
}

fn reject_signed_width_comparison(a: i16, b: i32) -> bool {
    // EXPECT_ERROR: E_NO_IMPLICIT_INTEGER_PROMOTION
    return a == b;
}

fn reject_bool_arithmetic(a: bool, b: bool) -> void {
    // EXPECT_ERROR: E_OPERATOR_OPERAND
    let x = a + b;
}

fn reject_integer_bool_arithmetic(a: u32, b: bool) -> void {
    // EXPECT_ERROR: E_OPERATOR_OPERAND
    let x = a + b;
}

fn reject_bool_negation(flag: bool) -> void {
    // EXPECT_ERROR: E_OPERATOR_OPERAND
    let x = -flag;
}

fn reject_pointer_negation(p: *mut u8) -> void {
    // EXPECT_ERROR: E_OPERATOR_OPERAND
    let x = -p;
}

fn reject_array_negation() -> void {
    var a: [2]u8 = uninit;
    // EXPECT_ERROR: E_OPERATOR_OPERAND
    let x = -a;
}

fn reject_bool_integer_equality(a: bool, b: u32) -> bool {
    // EXPECT_ERROR: E_OPERATOR_OPERAND
    return a == b;
}

fn reject_bool_integer_ordering(a: bool, b: u32) -> bool {
    // EXPECT_ERROR: E_OPERATOR_OPERAND
    return a < b;
}
