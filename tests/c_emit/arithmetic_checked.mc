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
