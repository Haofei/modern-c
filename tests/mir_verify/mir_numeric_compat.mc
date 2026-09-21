fn reject_signed_unsigned_arithmetic(a: i32, b: u32) -> i32 {
    return a + b;
}

fn reject_unsigned_signed_comparison(a: u32, b: i32) -> bool {
    return a < b;
}

fn reject_integer_width_arithmetic(a: u16, b: u32) -> u16 {
    return a + b;
}

fn reject_signed_width_comparison(a: i16, b: i32) -> bool {
    return a == b;
}

fn reject_f32_f64_mix(a: f32, b: f64) -> f64 {
    return a + b;
}

fn reject_float_int_mix(a: f32, b: u32) -> f32 {
    return a + b;
}

fn reject_float_remainder(a: f64, b: f64) -> f64 {
    return a % b;
}
