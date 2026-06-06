// SPEC: section=17,I.14
// SPEC: milestone=mmio-ordering
// SPEC: phase=sema,lower-c,lower-ir
// SPEC: expect=pass,compile_error,inspect
// SPEC: check=E_MMIO_DIRECT_ASSIGN,E_MMIO_REGISTER_WIDTH,E_MMIO_ACCESS_MODE,E_MMIO_REGBITS_TYPE,E_MMIO_PTR_TARGET,E_MMIO_REGISTER_POSITION,E_MMIO_ACCESS_FORBIDDEN,E_MMIO_ORDERING,E_CALL_ARG_COUNT,mmio-width-preserved,mmio-ordering-preserved,mmio-ir-width-preserved,mmio-ir-ordering-preserved

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

extern mmio struct RejectBadMmioRegisters {
    // EXPECT_ERROR: E_MMIO_REGISTER_WIDTH
    bool_width: Reg<bool, .read>,
    // EXPECT_ERROR: E_MMIO_REGISTER_WIDTH
    pointer_width: Reg<usize, .read>,
    // EXPECT_ERROR: E_MMIO_ACCESS_MODE
    bad_mode: Reg<u8, .bogus>,
    // EXPECT_ERROR: E_MMIO_REGISTER_WIDTH
    bad_bits_width: RegBits<bool, UartLsr, .read>,
    // EXPECT_ERROR: E_MMIO_REGBITS_TYPE
    bad_bits_layout: RegBits<u8, bool, .read>,
    // EXPECT_ERROR: E_MMIO_ACCESS_MODE
    bad_bits_mode: RegBits<u8, UartLsr, .bogus>,
}

extern struct Packet {
    value: u8,
}

extern struct RejectPlainRegisterField {
    // EXPECT_ERROR: E_MMIO_REGISTER_POSITION
    status: Reg<u8, .read>,
}

// EXPECT_ERROR: E_MMIO_REGISTER_POSITION
fn reject_register_parameter(status: Reg<u8, .read>) -> void {
    return;
}

fn reject_register_local() -> void {
    // EXPECT_ERROR: E_MMIO_REGISTER_POSITION
    var status: Reg<u8, .read> = uninit;
}

// EXPECT_ERROR: E_MMIO_REGISTER_POSITION
fn reject_regbits_parameter(status: RegBits<u8, UartLsr, .read>) -> void {
    return;
}

// EXPECT_ERROR: E_MMIO_PTR_TARGET
fn reject_mmio_ptr_scalar_target(uart: MmioPtr<u32>) -> void {
    return;
}

// EXPECT_ERROR: E_MMIO_PTR_TARGET
fn reject_mmio_ptr_plain_struct_target(uart: MmioPtr<Packet>) -> void {
    return;
}

fn putc(uart: MmioPtr<Uart16550>, ch: u8) -> void {
    while !uart.lsr.read(.acquire).tx_empty {
        cpu.pause();
    }

    // EXPECT: .release write emits mc_mmio_write_u8 and a release barrier before the access.
    uart.thr.write(ch, .release);
}

fn read_status(uart: MmioPtr<Uart16550>) -> UartLsr {
    // EXPECT: .acquire read emits mc_mmio_read_u8 and an acquire barrier after the access.
    let status = uart.lsr.read(.acquire);
    unsafe {
        raw.store<u8>(phys(0x2000_0000), 1);
    }
    return status;
}

fn reject_read_write_only_register(uart: MmioPtr<Uart16550>) -> u8 {
    // EXPECT_ERROR: E_MMIO_ACCESS_FORBIDDEN
    return uart.thr.read(.relaxed);
}

fn reject_write_read_only_register(uart: MmioPtr<Uart16550>, ch: u8) -> void {
    // EXPECT_ERROR: E_MMIO_ACCESS_FORBIDDEN
    uart.lsr.write(ch, .relaxed);
}

fn accept_read_write_register(uart: MmioPtr<Uart16550>, value: u8) -> u8 {
    uart.ier.write(value, .relaxed);
    return uart.ier.read(.relaxed);
}

fn reject_read_release_ordering(uart: MmioPtr<Uart16550>) -> UartLsr {
    // EXPECT_ERROR: E_MMIO_ORDERING
    return uart.lsr.read(.release);
}

fn reject_write_acquire_ordering(uart: MmioPtr<Uart16550>, ch: u8) -> void {
    // EXPECT_ERROR: E_MMIO_ORDERING
    uart.thr.write(ch, .acquire);
}

fn reject_read_unknown_ordering(uart: MmioPtr<Uart16550>) -> UartLsr {
    // EXPECT_ERROR: E_MMIO_ORDERING
    return uart.lsr.read(.bogus);
}

fn reject_write_non_literal_ordering(uart: MmioPtr<Uart16550>, ch: u8) -> void {
    // EXPECT_ERROR: E_MMIO_ORDERING
    uart.thr.write(ch, ch);
}

fn reject_read_missing_ordering(uart: MmioPtr<Uart16550>) -> UartLsr {
    // EXPECT_ERROR: E_CALL_ARG_COUNT
    return uart.lsr.read();
}

fn reject_write_missing_ordering(uart: MmioPtr<Uart16550>, ch: u8) -> void {
    // EXPECT_ERROR: E_CALL_ARG_COUNT
    uart.thr.write(ch);
}

fn reject_direct_mmio_assign(uart: MmioPtr<Uart16550>, ch: u8) -> void {
    // EXPECT_ERROR: E_MMIO_DIRECT_ASSIGN
    uart.thr = ch;
}

fn allow_plain_member_assign(packet: Packet, value: u8) -> void {
    // EXPECT: ordinary struct fields are not MMIO registers.
    var local: Packet = packet;
    local.value = value;
}

fn ordered_device_sequence(uart: MmioPtr<Uart16550>, ch: u8) -> void {
    // EXPECT: ordinary store cannot move after the release MMIO write.
    unsafe {
        raw.store<u8>(phys(0x2000_0000), ch);
    }
    uart.thr.write(ch, .release);
    let status = uart.lsr.read(.acquire);
    // EXPECT: ordinary store cannot move before the acquire MMIO read.
    unsafe {
        raw.store<u8>(phys(0x2000_0001), status.tx_empty as u8);
    }
    // EXPECT: lower-c/IR contains barriers or ordering markers that prevent reordering across release/acquire.
}
