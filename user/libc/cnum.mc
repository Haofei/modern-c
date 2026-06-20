// user/libc/cnum — C-ABI ctype classification + integer parsing (strtol/strtoul family) + the
// integer stdlib helpers, in MC. ASCII semantics; EOF(-1)-safe. The numeric parsers follow C:
// leading whitespace, optional sign, 0x/0 base prefixes, and an optional endptr output.
//
// strtod (floating) and the printf family live in separate modules.

import "std/addr.mc";

// ---- ctype (ASCII) ----

export fn isdigit(c: i32) -> i32 {
    if c >= 48 && c <= 57 {
        return 1;
    }
    return 0;
}

export fn isupper(c: i32) -> i32 {
    if c >= 65 && c <= 90 {
        return 1;
    }
    return 0;
}

export fn islower(c: i32) -> i32 {
    if c >= 97 && c <= 122 {
        return 1;
    }
    return 0;
}

export fn isalpha(c: i32) -> i32 {
    if isupper(c) != 0 || islower(c) != 0 {
        return 1;
    }
    return 0;
}

export fn isalnum(c: i32) -> i32 {
    if isalpha(c) != 0 || isdigit(c) != 0 {
        return 1;
    }
    return 0;
}

export fn isspace(c: i32) -> i32 {
    if c == 32 || c == 9 || c == 10 || c == 11 || c == 12 || c == 13 {
        return 1;
    }
    return 0;
}

export fn isxdigit(c: i32) -> i32 {
    if isdigit(c) != 0 || (c >= 97 && c <= 102) || (c >= 65 && c <= 70) {
        return 1;
    }
    return 0;
}

export fn iscntrl(c: i32) -> i32 {
    if (c >= 0 && c <= 31) || c == 127 {
        return 1;
    }
    return 0;
}

export fn isprint(c: i32) -> i32 {
    if c >= 32 && c <= 126 {
        return 1;
    }
    return 0;
}

export fn isgraph(c: i32) -> i32 {
    if c >= 33 && c <= 126 {
        return 1;
    }
    return 0;
}

export fn ispunct(c: i32) -> i32 {
    if isgraph(c) != 0 && isalnum(c) == 0 {
        return 1;
    }
    return 0;
}

export fn tolower(c: i32) -> i32 {
    if isupper(c) != 0 {
        return c + 32;
    }
    return c;
}

export fn toupper(c: i32) -> i32 {
    if islower(c) != 0 {
        return c - 32;
    }
    return c;
}

// ---- stdlib integer helpers ----

export fn abs(v: i32) -> i32 {
    if v < 0 {
        return -v;
    }
    return v;
}

export fn labs(v: i64) -> i64 {
    if v < 0 {
        return -v;
    }
    return v;
}

export fn llabs(v: i64) -> i64 {
    if v < 0 {
        return -v;
    }
    return v;
}

// ---- string -> integer ----

fn ld8(addr: usize) -> u8 {
    var b: u8 = 0;
    unsafe {
        b = raw.load<u8>(pa(addr));
    }
    return b;
}

// Map an ASCII digit/letter to its value (0..35), or 99 if it is not a base-36 digit.
fn digit_value(ch: u8) -> u32 {
    let c: u32 = ch as u32;
    if c >= 48 && c <= 57 {
        return c - 48; // '0'..'9'
    }
    if c >= 97 && c <= 122 {
        return c - 97 + 10; // 'a'..'z'
    }
    if c >= 65 && c <= 90 {
        return c - 65 + 10; // 'A'..'Z'
    }
    return 99;
}

// Shared unsigned core. Parses [ws][+/-][0x|0]digits, accumulates as u64, and reports the sign
// and the end address (one past the last consumed digit, or nptr if no digits were consumed).
struct ParsedInt {
    value: u64,
    negative: bool,
    end: usize,
}

fn parse_uint(nptr: usize, base_in: i32) -> ParsedInt {
    var p: usize = nptr;
    // skip whitespace
    while isspace(ld8(p) as i32) != 0 {
        p = p + 1;
    }
    // sign
    var negative: bool = false;
    let sign_ch: u8 = ld8(p);
    if sign_ch == 43 { // '+'
        p = p + 1;
    } else if sign_ch == 45 { // '-'
        negative = true;
        p = p + 1;
    }
    var base: u32 = base_in as u32;
    if base_in == 0 {
        base = 10;
        if ld8(p) == 48 { // leading '0'
            let n: u8 = ld8(p + 1);
            if n == 120 || n == 88 { // 'x'/'X'
                base = 16;
                p = p + 2;
            } else {
                base = 8;
            }
        }
    } else if base_in == 16 {
        if ld8(p) == 48 {
            let n: u8 = ld8(p + 1);
            if n == 120 || n == 88 {
                p = p + 2;
            }
        }
    }
    let digits_start: usize = p;
    var acc: u64 = 0;
    // bounded by the string length (each step advances p past a digit byte)
    while true {
        let dv: u32 = digit_value(ld8(p));
        if dv >= base {
            break;
        }
        acc = acc * (base as u64) + (dv as u64);
        p = p + 1;
    }
    var end: usize = p;
    if p == digits_start {
        end = nptr; // no conversion
    }
    return .{ .value = acc, .negative = negative, .end = end };
}

// Write the end pointer through endptr (a `char**`) when it is non-null.
fn store_end(endptr: usize, end: usize) -> void {
    if endptr != 0 {
        unsafe {
            raw.store<usize>(pa(endptr), end);
        }
    }
}

export fn strtoul(nptr: *const u8, endptr: *mut u8, base: i32) -> u64 {
    let r: ParsedInt = parse_uint(nptr as usize, base);
    store_end(endptr as usize, r.end);
    if r.negative {
        // C: a leading minus negates modulo 2^64. Two's complement = ~v + 1, computed without
        // the overflow trap a literal `0 - v` would hit: v>=1 keeps ~v <= 2^64-2, so +1 fits.
        if r.value == 0 {
            return 0;
        }
        return (~r.value) + 1;
    }
    return r.value;
}

export fn strtoull(nptr: *const u8, endptr: *mut u8, base: i32) -> u64 {
    return strtoul(nptr, endptr, base);
}

export fn strtol(nptr: *const u8, endptr: *mut u8, base: i32) -> i64 {
    let r: ParsedInt = parse_uint(nptr as usize, base);
    store_end(endptr as usize, r.end);
    if r.negative {
        return 0 - (r.value as i64);
    }
    return r.value as i64;
}

export fn strtoll(nptr: *const u8, endptr: *mut u8, base: i32) -> i64 {
    return strtol(nptr, endptr, base);
}

export fn atoi(nptr: *const u8) -> i32 {
    return strtol(nptr, uptr_null(), 10) as i32;
}

// A null `char**` endptr (parse without reporting the end).
fn uptr_null() -> *mut u8 {
    unsafe {
        return raw.ptr<u8>(0);
    }
}
