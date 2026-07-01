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

// A runtime (non-constant) index proven in range by a guard: the range-fact analysis proves
// `i < len` on the true path, so the bounds check is elided under --optimize and must stay
// behavior-preserving (the false path returns 0 without indexing).
fn guarded_index_demo(a: [4]u32, i: usize) -> u32 {
    if (i < 4) { return a[i]; }
    return 0;
}

// A runtime divisor proven non-zero by a guard: the DivideByZero check is elided under
// --optimize on the true path only.
fn guarded_div_demo(x: u32, d: u32) -> u32 {
    if (d != 0) { return x / d; }
    return 0;
}

// A runtime index summed under a `while (i < len)` guard: the loop-condition fact elides the
// per-iteration bounds check while staying behavior-identical to the checked build.
fn while_sum_demo(a: [4]u32) -> u32 {
    var acc: u32 = 0;
    var i: usize = 0;
    while (i < 4) {
        acc = acc + a[i];
        i = i + 1;
    }
    return acc;
}

// A struct-field array, indexed at a constant — exercises the member-base bounds elision.
struct Pair {
    vals: [2]u32,
}

fn pair_second(p: Pair) -> u32 {
    return p.vals[1];   // constant index into the struct field: bounds check elided under --optimize
}

// A constant range into a fixed array — exercises the const-slice construction bounds-check
// elision (`start <= end <= len`). Reads `.len` rather than indexing, so the only bounds check
// in play is the slice construction itself (a per-element index into the runtime-length slice
// would keep its own, non-elidable, check).
global slice_src: [6]u32;

fn slice_len_demo() -> u32 {
    let s: []mut u32 = slice_src[2..5];   // {.., .., ..}: construction bounds check elided under --optimize
    return s.len as u32;                  // 3
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
    let sl: u32 = slice_len_demo();                          // 3 (const-slice construction)
    let gi_src: [4]u32 = .{100, 200, 300, 400};
    let gi: u32 = guarded_index_demo(gi_src, 2);            // 300 (guard-proven runtime index)
    let gd: u32 = guarded_div_demo(90, 9);                 // 10 (guard-proven non-zero divisor)
    let ws: u32 = while_sum_demo(.{1, 2, 3, 4});           // 10 (while-guarded running index)
    // 5 + 7 + 50 + 3 + 300 + 10 + 10 = 385
    return base + ((signed_val + 10) as u32) + m + sl + gi + gd + ws;
}
