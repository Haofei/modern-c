// Runtime check for comptime-parameter monomorphization: `fill` depends on the
// comptime arg in its body, then the exported wrapper is concrete and linked/run
// by mono-test.sh.
fn fill(comptime N: usize, value: u8, idx: usize) -> u8 {
    let a: [4]u8 = .{ value, value, value, value };
    return a[idx % N];
}

export fn nth_of_filled(value: u8, idx: usize) -> u8 {
    return fill(4, value, idx);
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
