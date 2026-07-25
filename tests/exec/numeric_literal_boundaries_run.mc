const FOLDED_INFINITY: f64 = inf + 1.0;
const FOLDED_NAN: f64 = nan + 0.0;
const FOLDED_NEGATIVE_ZERO: f64 = -0.0 + -0.0;
const F32_EDGE: f32 = 16777216.0;
const F32_ONE: f32 = 1.0;
const F32_FOLDED: f32 = (F32_EDGE + F32_ONE) - F32_EDGE;
const NAN_SOURCE: u64 = 18444492273895871028;
const PAYLOAD_NAN: f64 = bitcast<f64>(NAN_SOURCE);
const F32_SNAN_SOURCE: u32 = 2139095041;
const F32_NEG_SNAN_SOURCE: u32 = 4286578689;
const F32_SNAN: f32 = bitcast<f32>(F32_SNAN_SOURCE);
const F32_NEG_SNAN: f32 = bitcast<f32>(F32_NEG_SNAN_SOURCE);

fn f32_runtime(a: f32, one: f32) -> f32 {
    return (a + one) - a;
}

export fn numeric_literal_boundaries_run() -> u32 {
    let high_bit: u128 = 1 << 127;
    let maximum: u128 = high_bit + (high_bit - 1);
    let separated_integer: f64 = 1_000.5;
    let ordinary_integer: f64 = 1000.5;
    let separated_fraction: f64 = 1.0_5;
    let ordinary_fraction: f64 = 1.05;
    let separated_exponent: f64 = 1.25e1_0;
    let ordinary_exponent: f64 = 12500000000.0;
    let direct_infinity: f64 = inf;
    let direct_nan: f64 = nan;
    let one: u64 = 1;
    let negative_zero_bits: u64 = one << 63;
    if 9223372036854775808 != 9223372036854775808 as u64 {
        return 1;
    }
    if 18446744073709551615 != 18446744073709551615 as u64 {
        return 2;
    }
    if 340282366920938463463374607431768211455 != maximum {
        return 3;
    }
    if bitcast<u64>(separated_integer) != bitcast<u64>(ordinary_integer) ||
        bitcast<u64>(separated_fraction) != bitcast<u64>(ordinary_fraction) ||
        bitcast<u64>(separated_exponent) != bitcast<u64>(ordinary_exponent) {
        return 4;
    }
    if bitcast<u64>(FOLDED_INFINITY) != bitcast<u64>(direct_infinity) {
        return 5;
    }
    if bitcast<u64>(FOLDED_NAN) != bitcast<u64>(direct_nan) {
        return 6;
    }
    if bitcast<u64>(FOLDED_NEGATIVE_ZERO) != negative_zero_bits {
        return 7;
    }
    if bitcast<u32>(F32_FOLDED) != bitcast<u32>(f32_runtime(F32_EDGE, F32_ONE)) {
        return 8;
    }
    if bitcast<u64>(PAYLOAD_NAN) != NAN_SOURCE {
        return 9;
    }
    if bitcast<u32>(F32_SNAN) != F32_SNAN_SOURCE {
        return 10;
    }
    if bitcast<u32>(F32_NEG_SNAN) != F32_NEG_SNAN_SOURCE {
        return 11;
    }
    if 0x20_u8 != 32_u8 ||
        1_u16 != 1 as u16 ||
        1_u32 != 1 as u32 ||
        1_u64 != 1 as u64 ||
        1_u128 != 1 as u128 ||
        1_usize != 1 as usize ||
        1_i8 != 1 as i8 ||
        1_i16 != 1 as i16 ||
        1_i32 != 1 as i32 ||
        1_i64 != 1 as i64 ||
        1_i128 != 1 as i128 ||
        1_isize != 1 as isize {
        return 12;
    }
    return 0;
}
