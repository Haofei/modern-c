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
