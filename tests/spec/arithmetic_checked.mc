// SPEC: section=5.1,G
// SPEC: milestone=arithmetic-semantics
// SPEC: phase=run,sema,lower-c
// SPEC: expect=trap,compile_error,inspect
// SPEC: check=IntegerOverflow,DivideByZero,E_UNSIGNED_NEGATION,E_ARITH_POLICY_MIX,checked-arithmetic-lowering

fn add_overflow_u32(a: u32) -> u32 {
    return a + 1;
}

fn sub_underflow_u32(a: u32) -> u32 {
    return a - 1;
}

fn mul_overflow_u32(a: u32) -> u32 {
    return a * 2;
}

fn div_zero_u32(a: u32) -> u32 {
    return a / 0;
}

fn signed_div_min_overflow() -> i32 {
    let x: i32 = -2147483648;
    return x / -1;
}

fn signed_rem_min_overflow() -> i32 {
    let x: i32 = -2147483648;
    return x % -1;
}

fn signed_neg_min_overflow() -> i32 {
    let x: i32 = -2147483648;
    return -x;
}

// EXPECT: run add_overflow_u32(4294967295) traps .IntegerOverflow.
// EXPECT: run sub_underflow_u32(0) traps .IntegerOverflow.
// EXPECT: run mul_overflow_u32(2147483648) traps .IntegerOverflow.
// EXPECT: run div_zero_u32(1) traps .DivideByZero.
// EXPECT: run signed_div_min_overflow() traps .IntegerOverflow before target division.
// EXPECT: run signed_rem_min_overflow() traps .IntegerOverflow before target remainder.
// EXPECT: run signed_neg_min_overflow() traps .IntegerOverflow before target negation.
// EXPECT: lower-c for checked + uses an overflow helper/check, not plain wrapping arithmetic alone.

fn reject_unsigned_negation(x: u32) -> u32 {
    // EXPECT_ERROR: E_UNSIGNED_NEGATION
    return -x;
}

fn reject_policy_mixing(a: u32, b: wrap<u32>) -> u32 {
    // EXPECT_ERROR: E_ARITH_POLICY_MIX
    return a + b;
}
