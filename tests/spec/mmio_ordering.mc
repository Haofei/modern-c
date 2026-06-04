// SPEC: section=17,I.14
// SPEC: milestone=mmio-ordering
// SPEC: phase=sema,lower-c,lower-ir
// SPEC: expect=pass,compile_error,inspect
// SPEC: check=E_MMIO_DIRECT_ASSIGN,mmio-width-preserved,mmio-ordering-preserved,mmio-ir-width-preserved,mmio-ir-ordering-preserved

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

    // EXPECT: .release write preserves u8 width, volatility, address space, and release ordering.
    uart.thr.write(ch, .release);
}

fn read_status(uart: MmioPtr<Uart16550>) -> UartLsr {
    // EXPECT: .acquire read preserves u8 width and prevents later operations moving before it.
    let status = uart.lsr.read(.acquire);
    raw.store<u8>(phys(0x2000_0000), 1);
    return status;
}

fn reject_direct_mmio_assign(uart: MmioPtr<Uart16550>, ch: u8) -> void {
    // EXPECT_ERROR: E_MMIO_DIRECT_ASSIGN
    uart.thr = ch;
}

fn allow_plain_member_assign(packet: Packet, value: u8) -> void {
    // EXPECT: ordinary struct fields are not MMIO registers.
    packet.value = value;
}

fn ordered_device_sequence(uart: MmioPtr<Uart16550>, ch: u8) -> void {
    raw.store<u8>(phys(0x2000_0000), ch);
    uart.thr.write(ch, .release);
    let status = uart.lsr.read(.acquire);
    raw.store<u8>(phys(0x2000_0001), status.tx_empty as u8);
    // EXPECT: lower-c/IR contains barriers or ordering markers that prevent reordering across release/acquire.
}
