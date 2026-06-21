// kernel/arch/riscv64/sbi_console — tiny number formatting over the SBI console
// putchar sink, in PURE MC. Reused by the bare-metal S-mode images that have no
// libc: print an unsigned decimal or a fixed-width 64-bit hex over `sbi_putchar`.
//
// No heap, no buffers beyond a fixed stack array. `put_dec` emits the digits of an
// unsigned value (special-casing 0); `put_hex` emits `0x` followed by all 16 nibbles
// (handy for dumping a scause/fault value).

import "kernel/arch/riscv64/sbi.mc";

// Print an unsigned 64-bit value in decimal (no leading zeros; "0" for zero).
export fn put_dec(v: u64) -> void {
    if v == 0 {
        sbi_putchar(48); // '0'
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
        sbi_putchar(buf[i]);
    }
}

// Print an unsigned 64-bit value as fixed-width 16-nibble hex with a "0x" prefix.
export fn put_hex(v: u64) -> void {
    sbi_putchar(48); // '0'
    sbi_putchar(120); // 'x'
    var s: i32 = 60;
    while s >= 0 {
        let nib: u64 = (v >> (s as u64)) & 0xF;
        if nib < 10 {
            sbi_putchar((48 + nib) as u8);       // '0'..'9'
        } else {
            sbi_putchar((87 + nib) as u8);       // 'a'..'f' ('a' == 97 == 87 + 10)
        }
        s = s - 4;
    }
}
