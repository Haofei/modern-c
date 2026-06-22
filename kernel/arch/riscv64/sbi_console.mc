// kernel/arch/riscv64/sbi_console — tiny number formatting over the SBI console
// putchar sink, in PURE MC. Reused by the bare-metal S-mode images that have no
// libc: print an unsigned decimal or a fixed-width 64-bit hex over `sbi_putchar`.
//
// The digit/nibble arithmetic lives once in `std/fmt_sink` (`fmt_put_*`); this module
// is the thin binding of those renderers to the `sbi_putchar` sink. `put_hex` is
// the 16-nibble (u64) form (handy for dumping a scause/fault value).

import "kernel/arch/riscv64/sbi.mc";
import "std/fmt_sink.mc";

// Print an unsigned 64-bit value in decimal (no leading zeros; "0" for zero).
export fn put_dec(v: u64) -> void {
    fmt_put_dec(sbi_putchar, v);
}

// Print an unsigned 64-bit value as fixed-width 16-nibble hex with a "0x" prefix.
export fn put_hex(v: u64) -> void {
    fmt_put_hex64(sbi_putchar, v);
}
