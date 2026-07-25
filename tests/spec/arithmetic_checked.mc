// SPEC: section=5.1,G
// SPEC: milestone=arithmetic-semantics
// SPEC: phase=run,sema,lower-c
// SPEC: expect=trap,compile_error,inspect
// SPEC: check=IntegerOverflow,DivideByZero,InvalidShift,E_UNSIGNED_NEGATION,E_ARITH_POLICY_MIX,checked-arithmetic-lowering

fn add_overflow_u32(a: u32) -> u32 {
    return a + 1;
}

fn sub_underflow_u32(a: u32) -> u32 {
    return a - 1;
}

fn mul_overflow_u32(a: u32) -> u32 {
    return a * 2;
}

fn mul_overflow_u64(a: u64, b: u64) -> u64 {
    return a * b;
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

fn left_shift_invalid_count(x: u32, n: u32) -> u32 {
    return x << n;
}

fn left_shift_overflow(x: u32, n: u32) -> u32 {
    return x << n;
}

fn right_shift_invalid_count(x: u32, n: u32) -> u32 {
    return x >> n;
}

fn suffixed_add_overflow_before_widen() -> u16 {
    return (255_u8 + 1_u8) as u16;
}

fn suffixed_add_before_widen_ok() -> u16 {
    return (1_u8 + 2_u8) as u16;
}

fn inferred_negated_suffix() -> i8 {
    let x = -1_i8;
    return x;
}

fn convert_negated_suffix() -> i16 {
    return i16.from(-1_i8);
}

// EXPECT: run add_overflow_u32(4294967295) traps .IntegerOverflow.
// EXPECT: run sub_underflow_u32(0) traps .IntegerOverflow.
// EXPECT: run mul_overflow_u32(2147483648) traps .IntegerOverflow.
// EXPECT: run mul_overflow_u64(18446744073709551615, 18446744073709551615) traps .IntegerOverflow.
// EXPECT: run div_zero_u32(1) traps .DivideByZero.
// EXPECT: run signed_div_min_overflow() traps .IntegerOverflow before target division.
// EXPECT: run signed_rem_min_overflow() traps .IntegerOverflow before target remainder.
// EXPECT: run signed_neg_min_overflow() traps .IntegerOverflow before target negation.
// EXPECT: run left_shift_invalid_count(1, 32) traps .InvalidShift.
// EXPECT: run left_shift_overflow(0x8000_0000, 1) traps .IntegerOverflow.
// EXPECT: run right_shift_invalid_count(1, 32) traps .InvalidShift.
// EXPECT: run suffixed_add_overflow_before_widen() traps .IntegerOverflow before widening.
// EXPECT: lower-c for checked + uses an overflow helper/check, not plain wrapping arithmetic alone.

fn reject_unsigned_negation(x: u32) -> u32 {
    // EXPECT_ERROR: E_UNSIGNED_NEGATION
    return -x;
}

fn reject_policy_mixing(a: u32, b: wrap<u32>) -> u32 {
    // EXPECT_ERROR: E_ARITH_POLICY_MIX
    return a + b;
}

fn reject_sat_policy_mixing(a: u32, b: sat<u32>) -> u32 {
    // EXPECT_ERROR: E_ARITH_POLICY_MIX
    return a + b;
}
