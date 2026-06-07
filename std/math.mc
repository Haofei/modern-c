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
