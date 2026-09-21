packed bits UartLsr: u8 {
    tx_empty: bool,
}

extern mmio struct Uart16550 {
    thr: Reg<u8, .write>,
    lsr: RegBits<u8, UartLsr, .read>,
}

#[irq_context]
extern fn irq_poll() -> void;

type IrqCounter = atomic<u32>;
type IrqUart = MmioPtr<Uart16550>;

fn store() -> void {}

#[irq_context]
fn accepted_irq() -> void {
    irq_poll();
}

#[irq_context]
fn accepted_atomic(flag: atomic<u32>, counter: IrqCounter, value: u32) -> void {
    flag.store(value, .release);
    counter.fetch_add(value, .acq_rel);
}

#[irq_context]
fn accepted_mmio(uart: IrqUart, value: u8) -> void {
    uart.thr.write(value, .release);
    let status = uart.lsr.read(.acquire);
}

#[irq_context]
fn accepted_builtins(addr: usize, token: u32) -> void {
    unsafe {
        raw.store<u32>(phys(addr), 0);
        forget_unchecked(token);
    }
}

#[irq_context]
fn rejected_store_name() -> void {
    store();
}

#[irq_context]
fn rejected_blocking(n: usize, path: u32) -> void {
    lock.acquire();
    heap.alloc(n);
    device.wait_irq();
    fs.read(path);
}
