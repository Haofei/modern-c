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
fn sum_u64(xs: []mut u64) -> Result<u64, Overflow> {
    return reduce.sum_checked<u64>(xs);
}

fn sum_left_f64(xs: []const f64) -> f64 {
    return reduce.sum_left<f64>(xs);
}

fn sum_fast_f32(xs: []const f32) -> f32 {
    return reduce.sum_fast<f32>(xs);
}

export fn reduce_sum_checked_run() -> u32 {
    let n3: usize = 3;

    var u32s: [3]u32 = .{ 1, 2, 3 };
    let u32_slice: []const u32 = u32s[0..n3];
    if let ok(v) = sum_u32(u32_slice) {
        if v != 6 { return 0; }
    } else {
        return 0;
    }

    var i32s: [3]i32 = .{ -4, 10, -1 };
    let i32_slice: []const i32 = i32s[0..n3];
    if let ok(v) = sum_i32(i32_slice) {
        if v != 5 { return 0; }
    } else {
        return 0;
    }

    var u8s: [3]u8 = .{ 10, 20, 30 };
    let u8_slice: []const u8 = u8s[0..n3];
    if let ok(v) = sum_u8(u8_slice) {
        if v != 60 { return 0; }
    } else {
        return 0;
    }

    var u64s: [3]u64 = .{ 40, 2, 1 };
    let u64_slice: []mut u64 = u64s[0..n3];
    if let ok(v) = sum_u64(u64_slice) {
        if v != 43 { return 0; }
    } else {
        return 0;
    }

    var f64s: [3]f64 = .{ 1.0, 2.0, 3.0 };
    let f64_slice: []const f64 = f64s[0..n3];
    if sum_left_f64(f64_slice) != 6.0 { return 0; }

    var f32s: [3]f32 = .{ 1.0, 2.0, 3.0 };
    let f32_slice: []const f32 = f32s[0..n3];
    if sum_fast_f32(f32_slice) != 6.0 { return 0; }

    return 1;
}
