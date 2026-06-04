// SPEC: section=6,D.1
// SPEC: milestone=bitwise-semantics
// SPEC: phase=sema,mir
// SPEC: expect=pass,compile_error,inspect
// SPEC: check=E_BITWISE_SIGNED_OPERAND,E_BITWISE_BOOL_OPERAND,E_BITWISE_POINTER_OPERAND,bitwise-no-trap

fn accept_unsigned_and(a: u32, b: u32) -> u32 {
    return a & b;
}

fn accept_unsigned_or(a: u32, b: u32) -> u32 {
    return a | b;
}

fn accept_unsigned_xor(a: u32, b: u32) -> u32 {
    return a ^ b;
}

fn accept_unsigned_not(a: u32) -> u32 {
    return ~a;
}

fn accept_unsigned_shift(a: u32, n: u32) -> u32 {
    return a << n;
}

fn reject_signed_and(a: i32, b: i32) -> i32 {
    // EXPECT_ERROR: E_BITWISE_SIGNED_OPERAND
    return a & b;
}

fn reject_signed_or(a: i32, b: i32) -> i32 {
    // EXPECT_ERROR: E_BITWISE_SIGNED_OPERAND
    return a | b;
}

fn reject_signed_xor(a: i32, b: i32) -> i32 {
    // EXPECT_ERROR: E_BITWISE_SIGNED_OPERAND
    return a ^ b;
}

fn reject_signed_not(a: i32) -> i32 {
    // EXPECT_ERROR: E_BITWISE_SIGNED_OPERAND
    return ~a;
}

fn reject_signed_left_shift(a: i32, n: u32) -> i32 {
    // EXPECT_ERROR: E_BITWISE_SIGNED_OPERAND
    return a << n;
}

fn reject_signed_right_shift(a: i32, n: u32) -> i32 {
    // EXPECT_ERROR: E_BITWISE_SIGNED_OPERAND
    return a >> n;
}

fn reject_bool_and(a: bool, b: bool) -> bool {
    // EXPECT_ERROR: E_BITWISE_BOOL_OPERAND
    return a & b;
}

fn reject_bool_not(a: bool) -> bool {
    // EXPECT_ERROR: E_BITWISE_BOOL_OPERAND
    return ~a;
}

fn reject_pointer_and(a: *mut u8, b: *mut u8) -> *mut u8 {
    // EXPECT_ERROR: E_BITWISE_POINTER_OPERAND
    return a & b;
}

fn reject_pointer_shift(a: *mut u8, n: u32) -> *mut u8 {
    // EXPECT_ERROR: E_BITWISE_POINTER_OPERAND
    return a << n;
}
