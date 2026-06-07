// MC standard library — `core`: pure scalar/bit utilities.
//
// Scope (a deliberately minimal v0; the design doc leaves the full library
// open): small, pure, total functions over the core scalar types. Every entry
// is a `const fn`, so it folds at comptime (usable in `comptime { assert … }`
// and as a `const` global initializer), and `export`ed, so it is also a
// linkable runtime symbol — compile this module to an object with `mcc-cc` and
// link it against application code.
//
// No allocation, I/O, MMIO, or other runtime effects: `core` is safe to call
// from any context, including comptime.

export const fn min_u32(a: u32, b: u32) -> u32 {
    switch a < b {
        true => { return a; },
        false => { return b; },
    }
}

export const fn max_u32(a: u32, b: u32) -> u32 {
    switch a > b {
        true => { return a; },
        false => { return b; },
    }
}

export const fn clamp_u32(x: u32, lo: u32, hi: u32) -> u32 {
    return min_u32(max_u32(x, lo), hi);
}

export const fn min_usize(a: usize, b: usize) -> usize {
    switch a < b {
        true => { return a; },
        false => { return b; },
    }
}

export const fn max_usize(a: usize, b: usize) -> usize {
    switch a > b {
        true => { return a; },
        false => { return b; },
    }
}

// True iff `x` is a non-zero power of two.
export const fn is_power_of_two(x: usize) -> bool {
    return x != 0 && (x & (x - 1)) == 0;
}

// Round `x` up to the next multiple of `a` (a must be a power of two).
export const fn align_up(x: usize, a: usize) -> usize {
    return (x + a - 1) & ~(a - 1);
}

// Round `x` down to the previous multiple of `a` (a must be a power of two).
export const fn align_down(x: usize, a: usize) -> usize {
    return x & ~(a - 1);
}
