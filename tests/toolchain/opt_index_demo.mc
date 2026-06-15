// Runtime fixture for the fact-gated optimizer equivalence test. The entry exercises all
// three transforms: several constant in-range array indices (Bounds-check elision), an
// unsigned division by a non-zero literal, and a SIGNED division by a non-zero/non-`-1`
// literal on a runtime-negative value (DivideByZero + INT_MIN/-1 overflow-check elision).
// The companion `opt-equiv-test.sh` runs this through the C and LLVM backends, with and
// without `--optimize`, and asserts all four executables produce the same result — i.e.
// eliding the provably-dead checks is behavior-preserving on both backends. The signed
// case specifically pins that C's checked-div helper and a plain `sdiv`/`/` truncate the
// negative quotient toward zero identically.

fn signed_div_demo(x: i32) -> i32 {
    return x / 2;   // signed div by the literal 2: both checks provably dead under --optimize
}

// A struct-field array, indexed at a constant — exercises the member-base bounds elision.
struct Pair {
    vals: [2]u32,
}

fn pair_second(p: Pair) -> u32 {
    return p.vals[1];   // constant index into the struct field: bounds check elided under --optimize
}

export fn opt_index_demo() -> u32 {
    let a: [5]u32 = .{2, 3, 5, 7, 11};
    var acc: u32 = a[0];   // 2
    acc = a[2];            // 5
    acc = a[4];            // 11
    let base: u32 = acc / 2;                                  // 11 / 2 = 5 (unsigned div by literal)
    let signed_val: i32 = signed_div_demo((a[1] as i32) - 10); // (3 - 10) / 2 = -7 / 2 = -3 (trunc)
    let p: Pair = .{ .vals = .{40, 50} };
    let m: u32 = pair_second(p);                             // 50 (member-base const index)
    return base + ((signed_val + 10) as u32) + m;            // 5 + 7 + 50 = 62
}
