// SPEC: section=6,D.1
// SPEC: milestone=bitwise-semantics
// SPEC: phase=sema,mir
// SPEC: expect=pass,compile_error,inspect
// SPEC: check=E_BITWISE_SIGNED_OPERAND,E_BITWISE_BOOL_OPERAND,E_BITWISE_POINTER_OPERAND,E_BITWISE_ARITH_DOMAIN_OPERAND,E_OPERATOR_OPERAND,bitwise-no-trap

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

fn accept_wrap_and(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
    return a & b;
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

fn reject_sat_and(a: sat<u32>, b: sat<u32>) -> sat<u32> {
    // EXPECT_ERROR: E_BITWISE_ARITH_DOMAIN_OPERAND
    return a & b;
}

fn reject_serial_xor(a: serial<u32>, b: serial<u32>) -> serial<u32> {
    // EXPECT_ERROR: E_BITWISE_ARITH_DOMAIN_OPERAND
    return a ^ b;
}

fn reject_counter_not(a: counter<u32>) -> counter<u32> {
    // EXPECT_ERROR: E_BITWISE_ARITH_DOMAIN_OPERAND
    return ~a;
}

fn reject_null_and() -> void {
    // EXPECT_ERROR: E_OPERATOR_OPERAND
    let x = null & null;
}

fn reject_array_and() -> void {
    var a: [2]u8 = uninit;
    var b: [2]u8 = uninit;
    // EXPECT_ERROR: E_OPERATOR_OPERAND
    let x = a & b;
}

fn reject_void_or() -> void {
    // EXPECT_ERROR: E_OPERATOR_OPERAND
    let x = () | ();
}

fn reject_null_not() -> void {
    // EXPECT_ERROR: E_OPERATOR_OPERAND
    let x = ~null;
}

fn reject_array_not() -> void {
    var a: [2]u8 = uninit;
    // EXPECT_ERROR: E_OPERATOR_OPERAND
    let x = ~a;
}
