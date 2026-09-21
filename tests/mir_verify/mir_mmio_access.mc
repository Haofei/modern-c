packed bits Status: u8 {
    ready: bool,
}

type TxReg = Reg<u8, .write>;
type StatusReg = RegBits<u8, Status, .read>;

extern mmio struct Uart {
    tx: TxReg,
    status: StatusReg,
    ctrl: Reg<u8, .read_write>,
}

fn reject_read_write_only(uart: MmioPtr<Uart>) -> u8 {
    return uart.tx.read(.relaxed);
}

fn reject_write_read_only(uart: MmioPtr<Uart>, value: u8) -> void {
    uart.status.write(value, .relaxed);
}

fn accept_read_write(uart: MmioPtr<Uart>, value: u8) -> u8 {
    uart.ctrl.write(value, .relaxed);
    return uart.ctrl.read(.relaxed);
}
