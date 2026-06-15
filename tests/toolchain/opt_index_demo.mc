// Runtime fixture for the fact-gated optimizer equivalence test. The entry exercises BOTH
// transforms: several constant in-range array indices (Bounds-check elision) and an unsigned
// division by a non-zero literal (DivideByZero-check elision). The companion
// `opt-equiv-test.sh` runs this through the C and LLVM backends, with and without
// `--optimize`, and asserts all four executables produce the same result — i.e. eliding the
// provably-dead checks is behavior-preserving on both backends.

export fn opt_index_demo() -> u32 {
    let a: [5]u32 = .{2, 3, 5, 7, 11};
    var acc: u32 = a[0];   // 2
    acc = a[2];            // 5
    acc = a[4];            // 11
    return acc / 2;        // 11 / 2 = 5 (unsigned div by literal: DivideByZero check elided)
}
