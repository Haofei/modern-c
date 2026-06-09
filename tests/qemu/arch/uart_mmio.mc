// QEMU MMIO execution test (§17): writes bytes to a real 16550 UART over typed
// MMIO. Lowered to C, linked into a bare-metal riscv64 image, and run under
// qemu-system-riscv64 -machine virt; the harness checks the UART output.
//
// The QEMU `virt` machine places a standard 8250/16550 UART at 0x1000_0000 with
// 1-byte registers, so this struct's u8 fields map to the hardware offsets.

extern mmio struct Uart16550 {
    thr: Reg<u8, .write>,
    ier: Reg<u8, .read_write>,
    iir: Reg<u8, .read_write>,
    lcr: Reg<u8, .read_write>,
    mcr: Reg<u8, .read_write>,
    lsr: Reg<u8, .read>,
}

// Write one byte to the transmit-holding register. The `.release` ordering
// makes earlier writes visible before this device handoff (§17).
export fn uart_putc(uart: MmioPtr<Uart16550>, ch: u8) -> void {
    uart.thr.write(ch, .release);
}
