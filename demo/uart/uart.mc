// demo/uart — typed MMIO registers.
//
// The access direction is part of each register's type, so the compiler rejects
// writing a read-only register or reading a write-only one. Register offsets are
// pinned with `@offset(N)`, so the struct reads like the datasheet's register map.

extern mmio struct Uart16550 {
    thr: Reg<u8, .write>        @offset(0x00), // transmit holding (write-only)
    ier: Reg<u8, .read_write>   @offset(0x01),
    fcr: Reg<u8, .write>        @offset(0x02),
    lcr: Reg<u8, .read_write>   @offset(0x03),
    mcr: Reg<u8, .read_write>   @offset(0x04),
    lsr: Reg<u8, .read>         @offset(0x05), // line status (read-only)
}

const LSR_THR_EMPTY: u8 = 0x20;

// Transmit one byte once the holding register is free.
export fn uart_putc(uart: MmioPtr<Uart16550>, ch: u8) -> void {
    while (uart.lsr.read(.acquire) & LSR_THR_EMPTY) == 0 {
    }
    uart.thr.write(ch, .release);
}

export fn uart_tx_ready(uart: MmioPtr<Uart16550>) -> bool {
    return (uart.lsr.read(.acquire) & LSR_THR_EMPTY) != 0;
}

// --- what the types forbid (uncomment → compile error) ---
//   uart.lsr.write(0, .release);  // E_MMIO_ACCESS_FORBIDDEN: lsr is read-only
//   let x = uart.thr.read(.acquire);  // E_MMIO_ACCESS_FORBIDDEN: thr is write-only
