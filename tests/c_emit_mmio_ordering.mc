packed bits UartLsr: u8 {
    data_ready: bool,
    overrun_error: bool,
    parity_error: bool,
    framing_error: bool,
    break_interrupt: bool,
    tx_empty: bool,
    tx_idle: bool,
    fifo_error: bool,
}

extern mmio struct Uart16550 {
    thr: Reg<u8, .write>,
    ier: Reg<u8, .read_write>,
    fcr: Reg<u8, .write>,
    lcr: Reg<u8, .read_write>,
    lsr: RegBits<u8, UartLsr, .read>,
}

extern struct Packet {
    value: u8,
}

fn putc(uart: MmioPtr<Uart16550>, ch: u8) -> void {
    while !uart.lsr.read(.acquire).tx_empty {
        cpu.pause();
    }

    uart.thr.write(ch, .release);
}

fn read_status(uart: MmioPtr<Uart16550>) -> UartLsr {
    let status = uart.lsr.read(.acquire);
    unsafe {
        raw.store<u8>(phys(0x2000_0000), 1);
    }
    return status;
}

fn accept_read_write_register(uart: MmioPtr<Uart16550>, value: u8) -> u8 {
    uart.ier.write(value, .relaxed);
    return uart.ier.read(.relaxed);
}

fn allow_plain_member_assign(packet: Packet, value: u8) -> void {
    var local: Packet = packet;
    local.value = value;
}

fn ordered_device_sequence(uart: MmioPtr<Uart16550>, ch: u8) -> void {
    unsafe {
        raw.store<u8>(phys(0x2000_0000), ch);
    }
    uart.thr.write(ch, .release);
    let status = uart.lsr.read(.acquire);
    unsafe {
        raw.store<u8>(phys(0x2000_0001), status.tx_empty as u8);
    }
}
