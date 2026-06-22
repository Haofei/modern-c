// kernel/platform/qemu_virt/console_hw — the board-specific backend for the panic console.
//
// This is the ONE place that knows the QEMU `virt` machine's 16550 UART transmit-hold
// register address. The kernel/core/console interface (console_putc/newline/puthex64) is
// board-agnostic and imports this through the `kernel/platform/active/` seam, so retargeting
// to another board is a `--platform=` selection rather than an edit of core.
//
// The single `unsafe` block is isolated here and justified: it is the one raw write to the
// platform's fixed debug-UART register, behind a safe typed API.

const PLAT_UART_THR: usize = 0x1000_0000; // QEMU virt 16550 transmit-hold register

export fn plat_console_putc(c: u8) -> void {
    unsafe {
        raw.store<u8>(phys(PLAT_UART_THR), c);
    }
}
