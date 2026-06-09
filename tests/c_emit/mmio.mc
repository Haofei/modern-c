packed bits UartLsr: u8 {
    data_ready: bool,
    tx_empty: bool,
}

extern mmio struct Uart16550 {
    thr: Reg<u8, .write>,
    raw: Reg<u8, .read>,
    lsr: RegBits<u8, UartLsr, .read>,
}

extern fn next_byte() -> u8;
extern fn box_byte(value: u8) -> u8;
extern fn combine_byte(left: u8, right: u8) -> u8;
extern fn consume_pair(left: u8, right: u8) -> void;

fn putc(uart: MmioPtr<Uart16550>, ch: u8) -> void {
    uart.thr.write(ch, .release);
}

fn putc_computed(uart: MmioPtr<Uart16550>) -> void {
    uart.thr.write(box_byte(next_byte()), .release);
}

fn read_status(uart: MmioPtr<Uart16550>) -> UartLsr {
    let status = uart.lsr.read(.acquire);
    return status;
}

fn status_tx_empty(uart: MmioPtr<Uart16550>) -> bool {
    let status = uart.lsr.read(.acquire);
    return status.tx_empty;
}

fn read_after_call(uart: MmioPtr<Uart16550>) -> u8 {
    return box_byte(next_byte()) + uart.raw.read(.acquire);
}

fn assign_read_after_call(uart: MmioPtr<Uart16550>) -> u8 {
    var value: u8 = 0;
    value = box_byte(next_byte()) + uart.raw.read(.acquire);
    return value;
}

fn call_read_after_call(uart: MmioPtr<Uart16550>) -> u8 {
    return combine_byte(box_byte(next_byte()), uart.raw.read(.acquire));
}

fn local_call_read_after_call(uart: MmioPtr<Uart16550>) -> u8 {
    let value: u8 = combine_byte(box_byte(next_byte()), uart.raw.read(.acquire));
    return value;
}

fn assign_call_read_after_call(uart: MmioPtr<Uart16550>) -> u8 {
    var value: u8 = 0;
    value = combine_byte(box_byte(next_byte()), uart.raw.read(.acquire));
    return value;
}

fn expr_call_read_after_call(uart: MmioPtr<Uart16550>) -> void {
    consume_pair(box_byte(next_byte()), uart.raw.read(.acquire));
}
