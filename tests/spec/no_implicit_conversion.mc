// SPEC: section=3,5
// SPEC: milestone=no-implicit-conversion
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_NO_IMPLICIT_CONVERSION,E_INTEGER_LITERAL_OUT_OF_RANGE

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

fn accept_hex_u8_max_literal() -> u8 {
    let x: u8 = 0xff;
    return x;
}

fn accept_same_width_local_initializer(a: u32) -> u32 {
    let x: u32 = a;
    return x;
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
