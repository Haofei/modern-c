// MC standard library — `bits`: pure bit-manipulation utilities.
//
// Same contract as `core` (see std/core.mc): every entry is a pure, total
// `const fn`, so it folds at comptime and is also an `export`ed linkable symbol.

// Population count: the number of set bits in `x`.
export const fn count_ones(x: u32) -> u32 {
    var n: u32 = x;
    var count: u32 = 0;
    while n != 0 {
        count = count + (n & 1);
        n = n >> 1;
    }
    return count;
}

// True iff `x` is a multiple of `a` (a must be a power of two).
export const fn is_aligned(x: usize, a: usize) -> bool {
    return (x & (a - 1)) == 0;
}

// A mask of the low `bits` bits set (saturates at the full 32-bit mask).
export const fn low_mask(bits: u32) -> u32 {
    switch bits >= 32 {
        true => { return 0xFFFFFFFF; },
        false => { return (1 << bits) - 1; },
    }
}

// True iff exactly one bit is set.
export const fn is_single_bit(x: u32) -> bool {
    return count_ones(x) == 1;
}

// Smallest power of two >= x (1 for x <= 1).
export const fn next_power_of_two(x: u32) -> u32 {
    var p: u32 = 1;
    while p < x {
        p = p * 2;
    }
    return p;
}

// Number of trailing zero bits (32 for x == 0).
export const fn trailing_zeros(x: u32) -> u32 {
    switch x == 0 {
        true => { return 32; },
        false => {
            var n: u32 = x;
            var count: u32 = 0;
            while (n & 1) == 0 {
                n = n >> 1;
                count = count + 1;
            }
            return count;
        },
    }
}

export const fn is_even(x: u32) -> bool {
    return (x & 1) == 0;
}

export const fn is_odd(x: u32) -> bool {
    return (x & 1) == 1;
}
