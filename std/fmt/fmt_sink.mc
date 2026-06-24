// MC standard library — `fmt_sink`: render integers and strings byte-by-byte into
// a caller-supplied sink. A "sink" is any `fn(u8) -> void` — a console `putc` such
// as `console_putc`, `sbi_putchar`, or a COM1/PL011 emitter.
//
// This is the digit/nibble arithmetic that kernel/core/mmio_console and the three
// arch consoles (riscv64/sbi_console, aarch64/pl011, x86_64/port_io) used to carry
// as four byte-identical copies. It lives here once; each console keeps only its
// one-byte primitive and forwards to these. No heap, no buffers beyond a fixed
// stack array, and — unlike `std/fmt`'s buffer-returning `format_u32` — no struct
// return, so the C backend emits no `memcpy`: these link into the most minimal
// freestanding image (no libc) that has a console but nothing else.
//
// These are plain (non-`export`) fns on purpose. A module's source is inlined into
// every importer's compilation unit, so an `export fn` becomes a GLOBAL symbol in
// each importing object; two objects in one link that both import this module would
// then collide (`ld.lld: duplicate symbol fmt_put_str`). Internal linkage emits a
// per-object `static` copy — safe to co-link, still callable across the import.

// Print a NUL-terminated byte string (read from raw memory) through `sink`.
fn fmt_put_str(sink: fn(u8) -> void, s: *const u8) -> void {
    let base: usize = s as usize;
    var i: usize = 0;
    while true {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + i)); }
        if b == 0 {
            break;
        }
        sink(b);
        i = i + 1;
    }
}

// Print an unsigned 64-bit value in decimal through `sink` (no leading zeros;
// "0" for zero).
fn fmt_put_dec(sink: fn(u8) -> void, v: u64) -> void {
    if v == 0 {
        sink(48); // '0'
        return;
    }
    // 20 digits is enough for any u64 (max 18446744073709551615).
    var buf: [20]u8 = .{ 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0 };
    var n: u64 = v;
    var i: usize = 0;
    while n > 0 {
        let d: u64 = n % 10;
        buf[i] = (48 + d) as u8; // '0' + digit
        n = n / 10;
        i = i + 1;
    }
    // Emit most-significant digit first (the buffer was filled least-significant).
    while i > 0 {
        i = i - 1;
        sink(buf[i]);
    }
}

// Shared nibble emitter: "0x" then the nibbles of `v` from bit `top_shift` down to
// bit 0, most significant first. `top_shift` selects the width (28 -> 8 nibbles,
// 60 -> 16 nibbles).
fn fmt_put_hex_from(sink: fn(u8) -> void, v: u64, top_shift: i32) -> void {
    sink(48);  // '0'
    sink(120); // 'x'
    var s: i32 = top_shift;
    while s >= 0 {
        let nib: u64 = (v >> (s as u64)) & 0xF;
        if nib < 10 {
            sink((48 + nib) as u8);       // '0'..'9'
        } else {
            sink((87 + nib) as u8);       // 'a'..'f' ('a' == 97 == 87 + 10)
        }
        s = s - 4;
    }
}

// Print an unsigned 32-bit value as `0x` + 8 fixed-width hex nibbles through `sink`.
fn fmt_put_hex32(sink: fn(u8) -> void, v: u32) -> void {
    fmt_put_hex_from(sink, v as u64, 28);
}

// Print an unsigned 64-bit value as `0x` + 16 fixed-width hex nibbles through `sink`.
fn fmt_put_hex64(sink: fn(u8) -> void, v: u64) -> void {
    fmt_put_hex_from(sink, v, 60);
}
