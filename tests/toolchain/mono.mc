// Runtime check for comptime-parameter monomorphization: `fill` is type-generic
// (its `[N]u8` depends on the comptime arg), specialized per call. The exported
// wrapper is concrete and is linked/run by mono-test.sh.
fn fill(comptime N: usize, value: u8) -> [N]u8 {
    var a: [N]u8 = uninit;
    var i: usize = 0;
    while i < N {
        a[i] = value;
        i = i + 1;
    }
    return a;
}

export fn nth_of_filled(value: u8, idx: usize) -> u8 {
    let a: [4]u8 = fill(4, value);
    return a[idx];
}

// A user-defined generic function, monomorphized per type argument.
fn max(comptime T: type, a: T, b: T) -> T {
    switch a > b {
        true => { return a; },
        false => { return b; },
    }
}

export fn max_u32(a: u32, b: u32) -> u32 {
    return max(u32, a, b);
}

// A user-defined generic struct, monomorphized per type argument.
struct Pair<T> {
    a: T,
    b: T,
}

fn mk_pair(comptime T: type, x: T, y: T) -> Pair<T> {
    return .{ .a = x, .b = y };
}

export fn pair_sum(x: u32, y: u32) -> u32 {
    let p: Pair<u32> = mk_pair(u32, x, y);
    return p.a + p.b;
}
