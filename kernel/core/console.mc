// kernel/core/console — the kernel's panic-safe debug console (board-agnostic interface).
//
// Writes single bytes through the platform's debug-UART backend, so it works from any
// context — including a trap handler before any driver is initialized — without depending
// on device setup, allocation, or runtime board config. The fixed UART register address
// lives in the board backend (kernel/platform/<board>/console_hw.mc), reached here through
// the `kernel/platform/active/` seam; this file stays free of any MMIO address so it never
// needs editing to retarget a board.
import "kernel/platform/active/console_hw.mc";
import "std/fmt_sink.mc";

export fn console_putc(c: u8) -> void {
    plat_console_putc(c);
}

export fn console_newline() -> void {
    console_putc('\n');
}

// Print a 64-bit value as `0x` followed by 16 hex digits (fixed width, no buffer).
// The nibble arithmetic is the shared sink renderer (std/fmt_sink); this stays a
// named entry so the panic path keeps calling `console_puthex64` unchanged.
export fn console_puthex64(v: u64) -> void {
    fmt_put_hex64(console_putc, v);
}
