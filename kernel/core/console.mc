// kernel/core/console — the kernel's panic-safe debug console (16550 UART).
//
// Writes bytes directly to the UART transmit register via `raw.store`, so it works
// from any context — including a trap handler before any driver is initialized —
// without depending on device setup, allocation, or board config. The single
// `unsafe` block is isolated here and justified: it is the one raw write to the
// platform's fixed debug-UART register, behind a safe typed API.

const UART_THR: usize = 0x1000_0000; // QEMU virt 16550 transmit-hold register

export fn console_putc(c: u8) -> void {
    unsafe {
        raw.store<u8>(phys(UART_THR), c);
    }
}

export fn console_newline() -> void {
    console_putc('\n');
}

// Print a 64-bit value as `0x` followed by 16 hex digits (fixed width, no buffer).
export fn console_puthex64(v: u64) -> void {
    console_putc('0');
    console_putc('x');
    var i: u32 = 0;
    while i < 16 {
        let shift: u32 = 60 - i * 4;
        let nibble: u8 = ((v >> shift) & 0xF) as u8;
        if nibble < 10 {
            console_putc(nibble + '0');
        } else {
            console_putc((nibble - 10) + 'a');
        }
        i = i + 1;
    }
}
