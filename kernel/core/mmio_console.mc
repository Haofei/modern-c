// kernel/core/mmio_console — tiny number/string formatting over the bare 16550
// UART sink (`console_putc`), in PURE MC. The M-mode analogue of
// kernel/arch/riscv64/sbi_console: an M-mode kernel booted with `-bios none` has
// NO firmware, so there is no SBI console ecall — it writes bytes straight to the
// 16550 transmit register (kernel/core/console).
//
// The digit/nibble arithmetic lives once in `std/fmt_sink` (`fmt_put_*`); this module
// is the thin binding of those renderers to the bare-UART `console_putc` sink, so
// the rest of the M-mode kernel sweep keeps calling `put_str`/`put_dec`/`put_hex`
// unchanged. `put_hex` is the 16-nibble (u64) form (handy for dumping an
// mcause/fault value).

import "console.mc";
import "std/fmt/fmt_sink.mc";

// Print a NUL-terminated string over the bare UART.
export fn put_str(s: *const u8) -> void {
    fmt_put_str(console_putc, s);
}

// Print an unsigned 64-bit value in decimal (no leading zeros; "0" for zero).
export fn put_dec(v: u64) -> void {
    fmt_put_dec(console_putc, v);
}

// Print an unsigned 64-bit value as fixed-width 16-nibble hex with a "0x" prefix.
export fn put_hex(v: u64) -> void {
    fmt_put_hex64(console_putc, v);
}
