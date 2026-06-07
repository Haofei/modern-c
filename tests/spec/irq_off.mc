// SPEC: section=19.1
// SPEC: milestone=irq-off-capability
// SPEC: phase=sema,lower-c
// SPEC: expect=pass,inspect
// SPEC: check=irq-off-capability

// IrqOff (§19.1): a critical section that requires interrupts disabled is
// expressed with a capability the operation takes, so the sequence cannot be
// written without first obtaining the witness. The capability is threaded as a
// value; affine/move-only enforcement is a deferred library-profile concern.

// Arch layer: disables interrupts and returns the witness; restore consumes it.
extern fn disable_interrupts() -> IrqOff;
extern fn restore_interrupts(cs: IrqOff) -> void;

// Requires interrupts disabled — only callable with an `IrqOff` capability.
// `cs` is a compile-time witness; it has no runtime use.
fn read_device(reg: u32, cs: IrqOff) -> u32 {
    return reg;
}

fn critical_read(reg: u32) -> u32 {
    let cs: IrqOff = disable_interrupts();
    let value: u32 = read_device(reg, cs);
    restore_interrupts(cs);
    return value;
}
