// MC standard library — `ascii`: pure ASCII character classification and
// conversion. Same contract as `core` (std/core.mc): every entry is a pure,
// total `const fn` that folds at comptime and is an `export`ed linkable symbol.

export const fn is_digit(c: u8) -> bool {
    return c >= '0' && c <= '9';
}

export const fn is_upper(c: u8) -> bool {
    return c >= 'A' && c <= 'Z';
}

export const fn is_lower(c: u8) -> bool {
    return c >= 'a' && c <= 'z';
}

export const fn is_alpha(c: u8) -> bool {
    return is_upper(c) || is_lower(c);
}

export const fn is_alnum(c: u8) -> bool {
    return is_alpha(c) || is_digit(c);
}

export const fn is_whitespace(c: u8) -> bool {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

// Uppercase an ASCII letter; other bytes are returned unchanged.
export const fn to_upper(c: u8) -> u8 {
    switch is_lower(c) {
        true => { return c - 32; },
        false => { return c; },
    }
}

// Lowercase an ASCII letter; other bytes are returned unchanged.
export const fn to_lower(c: u8) -> u8 {
    switch is_upper(c) {
        true => { return c + 32; },
        false => { return c; },
    }
}

// The numeric value of a decimal digit byte (0..9); 0 for non-digits.
export const fn digit_value(c: u8) -> u32 {
    switch is_digit(c) {
        true => { return (c - '0') as u32; },
        false => { return 0; },
    }
}
