packed bits UartLsr: u8 {
    tx_empty: bool,
}

extern mmio struct Uart16550 {
    thr: Reg<u8, .write>,
    lsr: RegBits<u8, UartLsr, .read>,
}

#[irq_context]
extern fn irq_poll() -> void;

type IrqUart = MmioPtr<Uart16550>;

#[irq_context]
fn call_irq_poll() -> void {
    irq_poll();
}

#[irq_context]
fn mmio_irq(uart: IrqUart, value: u8) -> bool {
    uart.thr.write(value, .release);
    let status = uart.lsr.read(.acquire);
    return status.tx_empty;
}
