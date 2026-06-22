// tests/qemu/lib/test_report — the bare-16550-UART reporting primitives shared by
// the riscv64 M-mode test runtimes (booted `-bios none`, so there is no firmware
// or SBI console). Each such runtime used to hand-roll an identical `uputc`/`uputs`
// pair over the QEMU 'virt' 16550 transmit-hold register; that pair lives here once.
// `uputs` reuses the std sink renderer (`fmt_put_str`), so the NUL-terminated string
// walk is shared with the kernel consoles too.
//
// Numeric reporting (decimal/hex) is intentionally NOT re-exported here: the few
// runtimes that print values import std/fmt_sink and call `fmt_put_dec`/
// `fmt_put_hex*` with `uputc` as the sink directly.

import "std/fmt_sink.mc";

const RT_UART_THR: usize = 0x1000_0000; // QEMU virt 16550 transmit-hold register

// Write one byte to the bare 16550 UART transmit register.
export fn uputc(c: u8) -> void {
    unsafe {
        raw.store<u8>(phys(RT_UART_THR), c);
    }
}

// Write a NUL-terminated string over the bare UART.
export fn uputs(s: *const u8) -> void {
    fmt_put_str(uputc, s);
}
