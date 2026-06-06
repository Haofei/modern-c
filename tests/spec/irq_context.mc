// SPEC: section=19.1,D.6
// SPEC: milestone=irq-context
// SPEC: phase=verifier
// SPEC: expect=reject,pass,inspect
// SPEC: check=E_IRQ_CONTEXT_CALL,E_IRQ_CONTEXT_BLOCKING,irq-context-verifier

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

fn ordinary_work() -> void {}

#[irq_context]
fn allow_irq_to_irq() -> void {
    irq_poll();
}

#[irq_context]
fn allow_atomic_and_mmio(flag: atomic<u32>, counter: IrqCounter, uart: IrqUart, value: u32, byte: u8) -> void {
    flag.store(value, .release);
    counter.fetch_add(value, .acq_rel);
    uart.thr.write(byte, .release);
    let status = uart.lsr.read(.acquire);
}

#[irq_context]
fn reject_plain_call() -> void {
    // EXPECT_ERROR: E_IRQ_CONTEXT_CALL
    ordinary_work();
}

#[irq_context]
fn reject_indirect_call(callee: u32) -> void {
    // EXPECT_ERROR: E_IRQ_CONTEXT_CALL
    callee();
}

#[irq_context]
fn reject_blocking_calls(n: usize, path: u32) -> void {
    // EXPECT_ERROR: E_IRQ_CONTEXT_BLOCKING
    lock.acquire();
    // EXPECT_ERROR: E_IRQ_CONTEXT_BLOCKING
    heap.alloc(n);
    // EXPECT_ERROR: E_IRQ_CONTEXT_BLOCKING
    device.wait_irq();
    // EXPECT_ERROR: E_IRQ_CONTEXT_BLOCKING
    fs.read(path);
}
