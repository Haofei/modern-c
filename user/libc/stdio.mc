// user/libc/stdio — the C-ABI printf family (vsnprintf/snprintf/printf/fprintf + the character
// and string output functions), in MC, built on the `va.*` varargs intrinsics. The formatting
// QuickJS uses for diagnostics and internal string building.
//
// Output is abstracted by a `Sink`: either a bounded user buffer (vsnprintf/snprintf, C99
// truncation + count semantics) or the console (everything else), which streams through the
// `mc_console_write` hook (SYS_WRITE in a confined app; UART in the bare-metal tests).
//
// This module covers the integer/string/char/pointer specifiers with full flags/width/precision/
// length-modifier handling. Floating-point specifiers (%f/%e/%g) are a separate addition.

import "std/addr.mc";
import "user/libc/lcommon.mc";

// Console output hook — provided by the runtime (UART under test; SYS_WRITE in the app).
extern fn mc_console_write(buf: usize, len: usize) -> void;

const SINK_CHUNK: usize = 256;

// A formatting destination. `to_console != 0` streams via mc_console_write through `chunk`;
// otherwise bytes land in the user buffer at `buf` (capacity `cap`). `count` is the total bytes
// that WOULD be written (the C99 return), regardless of truncation.
struct Sink {
    buf: usize,
    cap: usize,
    count: usize,
    to_console: u8,
    chunk_len: usize,
    chunk: [SINK_CHUNK]u8,
}

global g_sink_zero_chunk: [SINK_CHUNK]u8;
global g_digits_zero: [24]u8;

fn sink_buffer(buf: usize, cap: usize) -> Sink {
    return .{ .buf = buf, .cap = cap, .count = 0, .to_console = 0, .chunk_len = 0, .chunk = g_sink_zero_chunk };
}

fn sink_console() -> Sink {
    return .{ .buf = 0, .cap = 0, .count = 0, .to_console = 1, .chunk_len = 0, .chunk = g_sink_zero_chunk };
}

fn sink_flush(s: *mut Sink) -> void {
    if s.to_console != 0 && s.chunk_len > 0 {
        mc_console_write((&s.chunk[0]) as usize, s.chunk_len);
        s.chunk_len = 0;
    }
}

fn sink_putc(s: *mut Sink, b: u8) -> void {
    if s.to_console != 0 {
        if s.chunk_len == SINK_CHUNK {
            sink_flush(s);
        }
        s.chunk[s.chunk_len] = b;
        s.chunk_len = s.chunk_len + 1;
    } else {
        // store only if it fits, leaving room for the trailing NUL (written by vsnprintf)
        if s.count + 1 < s.cap {
            unsafe {
                raw.store<u8>(pa(s.buf + s.count), b);
            }
        }
    }
    s.count = s.count + 1;
}

fn sink_pad(s: *mut Sink, b: u8, n: usize) -> void {
    var i: usize = 0;
    while i < n {
        sink_putc(s, b);
        i = i + 1;
    }
}

// Parsed conversion flags.
struct Flags {
    minus: u8, // '-' left-justify
    zero: u8,  // '0' zero-pad
    plus: u8,  // '+' force sign
    space: u8, // ' ' leading space on positives
    hash: u8,  // '#' alternate form
}

const DIGITS_LOWER: usize = 0; // sentinel; digit() picks the table
fn digit_char(v: u32, upper: u8) -> u8 {
    if v < 10 {
        return (48 + v) as u8; // '0'..'9'
    }
    if upper != 0 {
        return (65 + v - 10) as u8; // 'A'..
    }
    return (97 + v - 10) as u8; // 'a'..
}

// Format an unsigned magnitude with sign/prefix/precision/width/justification.
fn emit_int(s: *mut Sink, mag_in: u64, negative: u8, base: u32, upper: u8, f: Flags, width: usize, prec: i32) -> void {
    var digits: [24]u8 = g_digits_zero;
    var ndig: usize = 0;
    var mag: u64 = mag_in;
    if mag == 0 {
        if prec != 0 {
            digits[0] = 48; // '0'
            ndig = 1;
        }
    } else {
        while mag != 0 {
            digits[ndig] = digit_char((mag % (base as u64)) as u32, upper);
            ndig = ndig + 1;
            mag = mag / (base as u64);
        }
    }

    // sign / blank
    var sign: u8 = 0;
    if negative != 0 {
        sign = 45; // '-'
    } else if f.plus != 0 {
        sign = 43; // '+'
    } else if f.space != 0 {
        sign = 32; // ' '
    }

    // alternate-form prefix for hex
    var prefix0: u8 = 0;
    var prefix1: u8 = 0;
    var nprefix: usize = 0;
    if f.hash != 0 && base == 16 && ndig != 0 {
        prefix0 = 48; // '0'
        if upper != 0 {
            prefix1 = 88; // 'X'
        } else {
            prefix1 = 120; // 'x'
        }
        nprefix = 2;
    }
    if f.hash != 0 && base == 8 && (ndig == 0 || digits[ndig - 1] != 48) {
        prefix0 = 48; // '0'
        nprefix = 1;
    }

    // precision = minimum digit count
    var zeros_for_prec: usize = 0;
    if prec >= 0 && ndig < (prec as usize) {
        zeros_for_prec = (prec as usize) - ndig;
    }

    var sign_len: usize = 0;
    if sign != 0 {
        sign_len = 1;
    }
    let body: usize = sign_len + nprefix + zeros_for_prec + ndig;
    var pad: usize = 0;
    if width > body {
        pad = width - body;
    }
    var zero_pad: u8 = 0;
    if f.zero != 0 && f.minus == 0 && prec < 0 {
        zero_pad = 1;
    }

    if f.minus == 0 && zero_pad == 0 {
        sink_pad(s, 32, pad);
    }
    if sign != 0 {
        sink_putc(s, sign);
    }
    if nprefix >= 1 {
        sink_putc(s, prefix0);
    }
    if nprefix == 2 {
        sink_putc(s, prefix1);
    }
    if zero_pad != 0 {
        sink_pad(s, 48, pad);
    }
    sink_pad(s, 48, zeros_for_prec);
    // digits, most-significant first
    var i: usize = ndig;
    while i > 0 {
        i = i - 1;
        sink_putc(s, digits[i]);
    }
    if f.minus != 0 {
        sink_pad(s, 32, pad);
    }
}

// Length modifiers.
const LEN_NONE: u8 = 0;
const LEN_L: u8 = 1;   // long
const LEN_LL: u8 = 2;  // long long
const LEN_Z: u8 = 3;   // size_t
const LEN_H: u8 = 4;   // short
const LEN_HH: u8 = 5;  // char

// The core formatter. `ap` is a pointer to the caller's va_list cursor.
fn do_format(s: *mut Sink, fmt_addr: usize, ap: *mut va_list) -> usize {
    var p: usize = fmt_addr;
    while true {
        let ch: u8 = lc_ld8(p);
        if ch == 0 {
            break;
        }
        if ch != 37 { // not '%'
            sink_putc(s, ch);
            p = p + 1;
            continue;
        }
        p = p + 1; // consume '%'

        // flags
        var f: Flags = .{ .minus = 0, .zero = 0, .plus = 0, .space = 0, .hash = 0 };
        while true {
            let fc: u8 = lc_ld8(p);
            if fc == 45 { f.minus = 1; p = p + 1; continue; }
            if fc == 48 { f.zero = 1; p = p + 1; continue; }
            if fc == 43 { f.plus = 1; p = p + 1; continue; }
            if fc == 32 { f.space = 1; p = p + 1; continue; }
            if fc == 35 { f.hash = 1; p = p + 1; continue; }
            break;
        }

        // width (number or '*')
        var width: usize = 0;
        if lc_ld8(p) == 42 { // '*'
            var w: i32 = 0;
            unsafe { w = va.arg<i32>(ap); }
            p = p + 1;
            if w < 0 { f.minus = 1; width = (-w) as usize; } else { width = w as usize; }
        } else {
            while lc_ld8(p) >= 48 && lc_ld8(p) <= 57 {
                width = width * 10 + ((lc_ld8(p) - 48) as usize);
                p = p + 1;
            }
        }

        // precision ('.' number | '.' '*'), -1 == unspecified
        var prec: i32 = -1;
        if lc_ld8(p) == 46 { // '.'
            p = p + 1;
            if lc_ld8(p) == 42 { // '*'
                var pr: i32 = 0;
                unsafe { pr = va.arg<i32>(ap); }
                p = p + 1;
                if pr < 0 { prec = -1; } else { prec = pr; }
            } else {
                prec = 0;
                while lc_ld8(p) >= 48 && lc_ld8(p) <= 57 {
                    prec = prec * 10 + ((lc_ld8(p) - 48) as i32);
                    p = p + 1;
                }
            }
        }

        // length modifiers
        var len: u8 = LEN_NONE;
        let l0: u8 = lc_ld8(p);
        if l0 == 108 { // 'l'
            p = p + 1;
            if lc_ld8(p) == 108 { len = LEN_LL; p = p + 1; } else { len = LEN_L; }
        } else if l0 == 122 { // 'z'
            len = LEN_Z; p = p + 1;
        } else if l0 == 104 { // 'h'
            p = p + 1;
            if lc_ld8(p) == 104 { len = LEN_HH; p = p + 1; } else { len = LEN_H; }
        } else if l0 == 106 || l0 == 116 { // 'j' / 't'
            len = LEN_LL; p = p + 1;
        }

        // specifier
        let spec: u8 = lc_ld8(p);
        if spec == 0 {
            break;
        }
        p = p + 1;

        if spec == 100 || spec == 105 { // 'd' / 'i'
            var v: i64 = 0;
            if len == LEN_LL || len == LEN_L || len == LEN_Z {
                unsafe { v = va.arg<i64>(ap); }
            } else {
                var v32: i32 = 0;
                unsafe { v32 = va.arg<i32>(ap); }
                v = v32 as i64;
            }
            var neg: u8 = 0;
            var mag: u64 = 0;
            if v < 0 {
                neg = 1;
                // -v can overflow for INT64_MIN; build the magnitude via two's complement.
                mag = (~(v as u64)) + 1;
            } else {
                mag = v as u64;
            }
            emit_int(s, mag, neg, 10, 0, f, width, prec);
        } else if spec == 117 || spec == 120 || spec == 88 || spec == 111 { // u/x/X/o
            var v: u64 = 0;
            if len == LEN_LL || len == LEN_L || len == LEN_Z {
                unsafe { v = va.arg<u64>(ap); }
            } else {
                var v32: u32 = 0;
                unsafe { v32 = va.arg<u32>(ap); }
                v = v32 as u64;
            }
            var base: u32 = 10;
            var upper: u8 = 0;
            if spec == 120 { base = 16; }
            if spec == 88 { base = 16; upper = 1; }
            if spec == 111 { base = 8; }
            emit_int(s, v, 0, base, upper, f, width, prec);
        } else if spec == 99 { // 'c'
            var cv: i32 = 0;
            unsafe { cv = va.arg<i32>(ap); }
            var pad: usize = 0;
            if width > 1 { pad = width - 1; }
            if f.minus == 0 { sink_pad(s, 32, pad); }
            sink_putc(s, cv as u8);
            if f.minus != 0 { sink_pad(s, 32, pad); }
        } else if spec == 115 { // 's'
            var saddr: usize = 0;
            unsafe { saddr = va.arg<usize>(ap); }
            if saddr == 0 {
                saddr = nul_str(); // "(null)"
            }
            // length, bounded by precision
            var slen: usize = 0;
            if prec >= 0 {
                while slen < (prec as usize) && lc_ld8(saddr + slen) != 0 {
                    slen = slen + 1;
                }
            } else {
                while lc_ld8(saddr + slen) != 0 {
                    slen = slen + 1;
                }
            }
            var pad: usize = 0;
            if width > slen { pad = width - slen; }
            if f.minus == 0 { sink_pad(s, 32, pad); }
            var i: usize = 0;
            while i < slen {
                sink_putc(s, lc_ld8(saddr + i));
                i = i + 1;
            }
            if f.minus != 0 { sink_pad(s, 32, pad); }
        } else if spec == 112 { // 'p'
            var v: usize = 0;
            unsafe { v = va.arg<usize>(ap); }
            var pf: Flags = f;
            pf.hash = 1;
            emit_int(s, v as u64, 0, 16, 0, pf, width, -1);
        } else if spec == 37 { // '%'
            sink_putc(s, 37);
        } else {
            // unknown specifier: emit verbatim so nothing is silently lost
            sink_putc(s, 37);
            sink_putc(s, spec);
        }
    }
    return s.count;
}

// The address of a small "(null)" literal kept in rodata via a fixed byte array.
global g_null: [7]u8;
global g_null_init: u8;
fn nul_str() -> usize {
    if g_null_init == 0 {
        g_null[0] = 40;  // (
        g_null[1] = 110; // n
        g_null[2] = 117; // u
        g_null[3] = 108; // l
        g_null[4] = 108; // l
        g_null[5] = 41;  // )
        g_null[6] = 0;
        g_null_init = 1;
    }
    return (&g_null[0]) as usize;
}

// ---- public API: buffer sinks ----

export fn vsnprintf(buf: *mut u8, size: usize, fmt: *const u8, ap: va_list) -> i32 {
    var s: Sink = sink_buffer(buf as usize, size);
    // Work on a local copy of the cursor so va.arg advances our own state.
    var local_ap: va_list = ap;
    let n: usize = do_format(&s, fmt as usize, &local_ap);
    if size > 0 {
        var idx: usize = s.count;
        if idx >= size { idx = size - 1; }
        unsafe { raw.store<u8>(pa((buf as usize) + idx), 0); } // NUL-terminate
    }
    return n as i32;
}

export fn snprintf(buf: *mut u8, size: usize, fmt: *const u8, ...) -> i32 {
    var s: Sink = sink_buffer(buf as usize, size);
    var ap: va_list = va.start();
    let n: usize = do_format(&s, fmt as usize, &ap);
    va.end(&ap);
    if size > 0 {
        var idx: usize = s.count;
        if idx >= size { idx = size - 1; }
        unsafe { raw.store<u8>(pa((buf as usize) + idx), 0); }
    }
    return n as i32;
}

// ---- public API: console sinks ----

export fn vprintf(fmt: *const u8, ap: va_list) -> i32 {
    var s: Sink = sink_console();
    var local_ap: va_list = ap;
    let n: usize = do_format(&s, fmt as usize, &local_ap);
    sink_flush(&s);
    return n as i32;
}

export fn printf(fmt: *const u8, ...) -> i32 {
    var s: Sink = sink_console();
    var ap: va_list = va.start();
    let n: usize = do_format(&s, fmt as usize, &ap);
    va.end(&ap);
    sink_flush(&s);
    return n as i32;
}

export fn fprintf(stream: *mut u8, fmt: *const u8, ...) -> i32 {
    var s: Sink = sink_console();
    var ap: va_list = va.start();
    let n: usize = do_format(&s, fmt as usize, &ap);
    va.end(&ap);
    sink_flush(&s);
    return n as i32;
}

export fn vfprintf(stream: *mut u8, fmt: *const u8, ap: va_list) -> i32 {
    return vprintf(fmt, ap);
}

// ---- public API: character / string output ----

export fn putchar(c: i32) -> i32 {
    var b: [1]u8 = uninit;
    b[0] = c as u8;
    mc_console_write((&b[0]) as usize, 1);
    return c;
}

export fn fputc(c: i32, stream: *mut u8) -> i32 {
    return putchar(c);
}

export fn fputs(str: *const u8, stream: *mut u8) -> i32 {
    let base: usize = str as usize;
    var n: usize = 0;
    while lc_ld8(base + n) != 0 {
        n = n + 1;
    }
    if n > 0 {
        mc_console_write(base, n);
    }
    return 0;
}

export fn puts(str: *const u8) -> i32 {
    let base: usize = str as usize;
    var n: usize = 0;
    while lc_ld8(base + n) != 0 {
        n = n + 1;
    }
    if n > 0 {
        mc_console_write(base, n);
    }
    var nl: [1]u8 = uninit;
    nl[0] = 10; // '\n'
    mc_console_write((&nl[0]) as usize, 1);
    return 0;
}

export fn fwrite(ptr: *const u8, size: usize, nmemb: usize, stream: *mut u8) -> usize {
    let total: usize = size * nmemb;
    if total > 0 {
        mc_console_write(ptr as usize, total);
    }
    return nmemb;
}

export fn fflush(stream: *mut u8) -> i32 {
    return 0;
}
