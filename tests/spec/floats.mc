// SPEC: section=3,8.3
// SPEC: milestone=floating-point-scalars
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_NO_IMPLICIT_CONVERSION,E_OPERATOR_OPERAND,E_RETURN_TYPE_MISMATCH

// f32/f64 are fixed-width scalar types (section 3).
fn fadd(a: f32, b: f32) -> f32 {
    return a + b;
}

fn fsub(a: f64, b: f64) -> f64 {
    return a - b;
}

fn fmul(a: f32, b: f32) -> f32 {
    return a * b;
}

// Floating-point division does not trap; it yields IEEE infinities/NaN.
fn fdiv(a: f64, b: f64) -> f64 {
    return a / b;
}

// Ordering and equality are defined on floats.
fn fcmp(a: f32, b: f32) -> bool {
    return a < b;
}

fn feq(a: f64, b: f64) -> bool {
    return a == b;
}

fn fneg(a: f64) -> f64 {
    return -a;
}

// Float literals are context-typed.
fn fliteral() -> f32 {
    let x: f32 = 1.5;
    return x;
}

fn fliteral_arith(a: f32) -> f32 {
    return a + 2.5;
}

// A simple floating-point reduction (section 8.3).
fn reduce(a: f64, b: f64, c: f64) -> f64 {
    return a + b + c;
}

// f32 and f64 do not implicitly convert.
fn reject_f32_f64_mix(a: f32, b: f64) -> f64 {
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    return a + b;
}

// Floating-point and integer operands do not implicitly mix.
fn reject_float_int_mix(a: f32, b: u32) -> f32 {
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    return a + b;
}

// Bitwise operations are not defined on floats.
fn reject_float_bitwise(a: f32, b: f32) -> f32 {
    // EXPECT_ERROR: E_OPERATOR_OPERAND
    return a & b;
}

// Remainder is not defined on floats.
fn reject_float_remainder(a: f64, b: f64) -> f64 {
    // EXPECT_ERROR: E_OPERATOR_OPERAND
    return a % b;
}

// Integer literals do not implicitly become floats.
fn reject_int_literal_to_float() -> f32 {
    // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
    return 5;
}
