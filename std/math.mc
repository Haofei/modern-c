// MC standard library — `math`: pure integer-math utilities.
//
// Same contract as `core` (see std/core.mc): every entry is a pure, total
// `const fn`, so it folds at comptime and is also an `export`ed linkable symbol.

// Greatest common divisor (Euclid's algorithm). gcd(x, 0) == x.
export const fn gcd(a: u32, b: u32) -> u32 {
    var x: u32 = a;
    var y: u32 = b;
    while y != 0 {
        let t: u32 = y;
        y = x % y;
        x = t;
    }
    return x;
}

// Least common multiple. lcm(0, _) == 0.
export const fn lcm(a: u32, b: u32) -> u32 {
    switch a == 0 {
        true => { return 0; },
        false => { return (a / gcd(a, b)) * b; },
    }
}

// Integer exponiation: base**exp (wraps on u32 overflow at runtime; folds at
// comptime within range).
export const fn pow_u32(base: u32, exp: u32) -> u32 {
    var result: u32 = 1;
    var e: u32 = exp;
    while e != 0 {
        result = result * base;
        e = e - 1;
    }
    return result;
}

// Integer base-2 logarithm (floor); ilog2(0) == 0 by convention.
export const fn ilog2(x: u32) -> u32 {
    var n: u32 = x;
    var log: u32 = 0;
    while n > 1 {
        n = n >> 1;
        log = log + 1;
    }
    return log;
}

// Wrapping (modulo-2^32) 32-bit add. Computes in 64-bit then truncates, so it never
// triggers the checked-overflow trap — for modular arithmetic like TCP sequence
// numbers, where wraparound is correct, not an error.
export const fn wrapping_add_u32(a: u32, b: u32) -> u32 {
    return (((a as u64) + (b as u64)) & 0x0000_0000_FFFF_FFFF) as u32;
}

// Wrapping (modulo-2^32) 32-bit subtract. `a + 2^32 - b` stays positive in 64 bits.
export const fn wrapping_sub_u32(a: u32, b: u32) -> u32 {
    return (((a as u64) + 0x0000_0001_0000_0000 - (b as u64)) & 0x0000_0000_FFFF_FFFF) as u32;
}

// Wrapping (modulo-2^32) 32-bit left shift: bits shifted past bit 31 are discarded
// rather than overflowing (the checked `<<` would trap). For hashes / PRNGs where
// the wraparound is intended. `n` must be < 32.
export const fn wrapping_shl_u32(x: u32, n: u32) -> u32 {
    return (((x as u64) << (n as u64)) & 0x0000_0000_FFFF_FFFF) as u32;
}
