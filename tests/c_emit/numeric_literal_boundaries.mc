const U64_MAXIMUM: u64 = 18446744073709551615;
const U128_MAXIMUM: u128 = 340282366920938463463374607431768211455;
const U128_HIGH_BIT: u128 = 1 << 127;
const U128_COMPOSED_MAXIMUM: u128 = U128_HIGH_BIT + (U128_HIGH_BIT - 1);
const POSITIVE_INFINITY: f64 = inf + 1.0;
const QUIET_NAN: f64 = nan + 0.0;

const fn const_u128_identity(value: u128) -> u128 {
    return value;
}

const CONST_FN_U128_MAXIMUM: u128 =
    const_u128_identity(340282366920938463463374607431768211455);
const U128_VALUES: [2]u128 =
    .{ 18446744073709551616, 340282366920938463463374607431768211455 };

struct WideValues {
    unsigned_value: u128,
    signed_value: i128,
    separated_float: f64,
}

fn accept_u128(value: u128) -> u128 {
    return value;
}

fn u64_edge() -> u64 {
    return 9223372036854775808;
}

fn u64_maximum() -> u64 {
    return 18446744073709551615;
}

fn two_to_64() -> u128 {
    return 18446744073709551616;
}

fn u128_maximum() -> u128 {
    return 340282366920938463463374607431768211455;
}

fn i128_minimum() -> i128 {
    return -170141183460469231731687303715884105728;
}

fn separated_return() -> f64 {
    return 1_2.3_4e5_6;
}

fn separated_local() -> f32 {
    let value: f32 = 1_000.5;
    return value;
}

fn separated_argument() -> f64 {
    return 1.0_5 + 1.25e1_0;
}

fn wide_argument() -> u128 {
    return accept_u128(340282366920938463463374607431768211455);
}

fn wide_assignment() -> u128 {
    var value: u128 = 0;
    value = 340282366920938463463374607431768211455;
    return value;
}

fn wide_cast() -> u128 {
    return 340282366920938463463374607431768211455 as u128;
}

fn aggregate_values() -> WideValues {
    return .{
        .unsigned_value = 340282366920938463463374607431768211455,
        .signed_value = -170141183460469231731687303715884105728,
        .separated_float = 1.25e1_0,
    };
}

fn folded_infinity() -> f64 {
    return POSITIVE_INFINITY;
}

fn folded_nan() -> f64 {
    return QUIET_NAN;
}
