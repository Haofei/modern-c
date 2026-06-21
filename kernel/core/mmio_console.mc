// kernel/core/mmio_console — tiny number/string formatting over the bare 16550
// UART sink (`console_putc`), in PURE MC. The M-mode analogue of
// kernel/arch/riscv64/sbi_console: an M-mode kernel booted with `-bios none` has
// NO firmware, so there is no SBI console ecall — it writes bytes straight to the
// 16550 transmit register (kernel/core/console). This module mirrors
// sbi_console.mc's shape exactly, just over `console_putc` instead of
// `sbi_putchar`, so the rest of the M-mode kernel sweep can reuse it.
//
// No heap, no buffers beyond a fixed stack array. `put_dec` emits the digits of an
// unsigned value (special-casing 0); `put_hex` emits `0x` followed by all 16
// nibbles (handy for dumping an mcause/fault value); `put_str` walks a
// NUL-terminated byte string.

import "console.mc";

// Print a NUL-terminated string over the bare UART.
export fn put_str(s: *const u8) -> void {
    let base: usize = s as usize;
    var i: usize = 0;
    while true {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + i)); }
        if b == 0 {
            break;
        }
        console_putc(b);
        i = i + 1;
    }
}

// Print an unsigned 64-bit value in decimal (no leading zeros; "0" for zero).
export fn put_dec(v: u64) -> void {
    if v == 0 {
        console_putc(48); // '0'
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
        console_putc(buf[i]);
    }
}

// Print an unsigned 64-bit value as fixed-width 16-nibble hex with a "0x" prefix.
export fn put_hex(v: u64) -> void {
    console_putc(48);  // '0'
    console_putc(120); // 'x'
    var s: i32 = 60;
    while s >= 0 {
        let nib: u64 = (v >> (s as u64)) & 0xF;
        if nib < 10 {
            console_putc((48 + nib) as u8);       // '0'..'9'
        } else {
            console_putc((87 + nib) as u8);       // 'a'..'f' ('a' == 97 == 87 + 10)
        }
        s = s - 4;
    }
}
