// Differential fixture for the u128 / i128 scalar integer types (128-bit integers,
// lowered to `unsigned __int128` / `__int128` in C and `i128` in LLVM). Exercises the
// 128-bit operations that BOTH backends lower inline (no compiler-rt libcall): widening
// and truncating casts, add/sub with carry across the 64-bit boundary, wrapping shifts,
// bitwise ops, comparisons, and signed negate. Entry mode diffs the C and LLVM return,
// so any backend disagreement on 128-bit arithmetic, the helper macros, or the cast
// paths fails.
//
// NOTE (tracked): 128-bit MULTIPLY and DIVIDE/MOD lower to compiler-rt routines
// (__multi3 / __muloti4 / __udivti3 / __umodti3 …) that a freestanding image does not
// link. The C backend inlines __builtin_*_overflow; llc emits a libcall. So u128 mul/div
// — and a bignum built on a single 128-bit limb — need those runtime routines provided
// first (or a bignum on u32 limbs, whose products fit u64, which stays libcall-free).
// This fixture deliberately avoids 128-bit mul/div so it is a clean cross-backend gate.

fn fold(x: u128) -> u32 {
    let lo: u64 = (x & 0xFFFF_FFFF_FFFF_FFFF) as u64;
    let hi: u64 = (x >> 64) as u64;
    return (lo as u32) ^ ((lo >> 32) as u32) ^ (hi as u32) ^ ((hi >> 32) as u32);
}

export fn u128_run() -> u32 {
    var acc: u32 = 0;

    // build a 128-bit value from two u64 limbs (widening casts + shift + or)
    let hi: u64 = 0xDEAD_BEEF_CAFE_F00D;
    let lo: u64 = 0x0123_4567_89AB_CDEF;
    let v: u128 = ((hi as u128) << 64) | (lo as u128);
    acc = acc ^ fold(v);

    // split back into limbs — truncating casts round-trip exactly
    if ((v >> 64) as u64) == hi { acc = acc ^ 0x1; }
    if ((v & 0xFFFF_FFFF_FFFF_FFFF) as u64) == lo { acc = acc ^ 0x2; }

    // add/sub with carry across the 64-bit boundary
    let a: u128 = (1 as u128) << 64;           // 2^64
    let b: u128 = a - 1;                        // 2^64 - 1 (all low bits set)
    let s: u128 = a + b;                        // 2^65 - 1
    acc = acc ^ fold(s);
    if (s - b) == a { acc = acc ^ 0x4; }

    // shifts and bitwise across 128 bits (right shifts + a non-lossy left shift, so the
    // default CHECKED shift does not trap on dropped high bits)
    acc = acc ^ fold((v >> 7) ^ (v >> 9));
    acc = acc ^ fold((v & a) | (b & v));
    if (a << 1) > a { acc = acc ^ 0x8; }      // 2^64 << 1 = 2^65, no bits lost
    if v >= b { acc = acc ^ 0x10; }

    // signed i128: negate, sign-correct add, comparison
    let sa: i128 = -(b as i128);               // -(2^64 - 1)
    let sb: i128 = sa + (b as i128);           // 0
    if sb == 0 { acc = acc ^ 0x20; }
    if sa < 0 { acc = acc ^ 0x40; }
    if (sa - 1) < sa { acc = acc ^ 0x80; }

    return acc;
}
