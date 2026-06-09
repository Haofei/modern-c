// reduce.sum_checked<T> (§8.2): a mathematical checked reduction. The sum is
// computed in a wide (__int128) accumulator and the *final* result is range-
// checked into T, returning Result<T, Overflow>. This differs from stepwise
// checked addition, which would trap on an intermediate overflow even when the
// mathematical sum fits T.

fn sum_u32(xs: []const u32) -> Result<u32, Overflow> {
    return reduce.sum_checked<u32>(xs);
}

// Signed element type: the lower bound is the negative type minimum.
fn sum_i32(xs: []const i32) -> Result<i32, Overflow> {
    return reduce.sum_checked<i32>(xs);
}

// Narrow element type widens correctly in the accumulator.
fn sum_u8(xs: []const u8) -> Result<u8, Overflow> {
    return reduce.sum_checked<u8>(xs);
}

// Mutable (non-const) slice element type is also accepted.
fn sum_u64(xs: []u64) -> Result<u64, Overflow> {
    return reduce.sum_checked<u64>(xs);
}
