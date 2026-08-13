// tests/qemu/support/core/console — panic-safe debug output for retained QEMU validation fixtures.
//
// Writes single bytes through the selected validation platform backend, so it works from trap
// handlers without depending on allocation or driver setup. The fixed UART register address stays
// behind the QEMU support console backend.
import "tests/qemu/support/platform/qemu_virt/console_hw.mc";
import "std/fmt/fmt_sink.mc";

#[mc_abi]
export fn console_putc(c: u8) -> void {
    plat_console_putc(c);
}

#[mc_abi]
export fn console_newline() -> void {
    console_putc('\n');
}

// Print a 64-bit value as `0x` followed by 16 hex digits (fixed width, no buffer).
// The nibble arithmetic is the shared sink renderer (std/fmt_sink); this stays a
// named entry so the panic path keeps calling `console_puthex64` unchanged.
#[mc_abi]
export fn console_puthex64(v: u64) -> void {
    fmt_put_hex64(console_putc, v);
}
