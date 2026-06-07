// MC standard library — `fmt`: integer formatting. Kernels need to render
// numbers without libc; these are pure `const fn`s (fold at comptime, link as
// runtime symbols) that produce a fixed-size digit buffer plus its length.

// A formatted decimal: `digits[0 .. len]` are the ASCII digits, most
// significant first. u32 needs at most 10 digits.
extern struct U32Decimal {
    digits: [10]u8,
    len: usize,
}

// ASCII byte for a single decimal digit value (0..9).
export const fn digit_char(d: u32) -> u8 {
    return (d as u8) + '0';
}

// Render `value` as decimal ASCII digits (most significant first).
export const fn format_u32(value: u32) -> U32Decimal {
    var tmp: [10]u8 = uninit;
    var n: u32 = value;
    var count: usize = 0;
    // Extract digits least-significant first (always at least one for 0).
    while true {
        tmp[count] = digit_char(n % 10);
        count = count + 1;
        n = n / 10;
        switch n == 0 {
            true => { break; },
            false => {},
        }
    }
    // Reverse into the result so the most significant digit comes first.
    var out: [10]u8 = uninit;
    var i: usize = 0;
    while i < count {
        out[i] = tmp[count - 1 - i];
        i = i + 1;
    }
    return .{ .digits = out, .len = count };
}
