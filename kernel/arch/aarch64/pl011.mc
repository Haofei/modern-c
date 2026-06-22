// kernel/arch/aarch64/pl011 — the ARM PL011 UART over MMIO, a console in PURE MC.
//
// The AArch64 analogue of kernel/arch/x86_64/port_io (COM1) and kernel/arch/riscv64/sbi
// (SBI console): the one place the platform's serial primitive lives, behind a typed safe
// API. Unlike x86 (port I/O instructions) the PL011 is plain MMIO, so there is NO inline
// asm here at all — `console_putc` polls the flag register's TX-FIFO-full bit then stores
// the byte to the data register through `raw.store<u8>`. This is the reusable ARM console
// the rest of the aarch64 sweep (vm/user/qjs/context kmains) prints through.

import "std/fmt_sink.mc";

// QEMU 'virt' PL011 base. DR is at +0x00 (write a byte to transmit); FR (flag register) is
// at +0x18, with bit 5 = TXFF (transmit FIFO full) — we spin while it is set so we never
// overrun the FIFO. No initialisation is required: QEMU's PL011 transmits at reset.
const PL011_DR: usize = 0x0900_0000;        // base + 0x00: data register
const PL011_FR: usize = 0x0900_0018;        // base + 0x18: flag register
const FR_TXFF: u8 = 0x20;                   // bit 5: transmit FIFO full

// Emit one byte, polling the flag register's TXFF bit so a write never overruns the FIFO.
export fn console_putc(c: u8) -> void {
    while true {
        var fr: u8 = 0;
        unsafe { fr = raw.load<u8>(phys(PL011_FR)); }
        if (fr & FR_TXFF) == 0 {
            break;
        }
    }
    unsafe { raw.store<u8>(phys(PL011_DR), c); }
}

// The digit/nibble arithmetic lives once in `std/fmt_sink` (`fmt_put_*`); the
// renderers below are the thin binding of those to this PL011 `console_putc` sink.

// Print a NUL-terminated byte string read from raw memory.
export fn put_str(s: *const u8) -> void {
    fmt_put_str(console_putc, s);
}

// Print an unsigned 32-bit value as `0x` + 8 fixed-width hex nibbles.
export fn put_hex(v: u32) -> void {
    fmt_put_hex32(console_putc, v);
}

// Print an unsigned 64-bit value as `0x` + 16 fixed-width hex nibbles.
export fn put_hex64(v: u64) -> void {
    fmt_put_hex64(console_putc, v);
}

// Print an unsigned 64-bit value in decimal (no leading zeros; "0" for zero).
export fn put_dec(v: u64) -> void {
    fmt_put_dec(console_putc, v);
}
