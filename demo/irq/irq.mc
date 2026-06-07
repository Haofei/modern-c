// demo/irq — interrupt lifecycle + the IrqOff capability (§19.1).
//
// An interrupt source moves through Masked → Enabled → Pending → Enabled. `ack`
// takes an IrqPending, so you cannot acknowledge an interrupt that has not fired.
// Separately, code that touches data shared with the handler requires an `IrqOff`
// witness, proving interrupts are disabled around it.

move struct IrqMasked { line: u32 }
move struct IrqEnabled { line: u32 }
move struct IrqPending { line: u32 }

extern fn mc_irq_register(line: u32) -> IrqMasked;
extern fn mc_irq_unmask(s: IrqMasked) -> IrqEnabled;
extern fn mc_irq_mask(s: IrqEnabled) -> IrqMasked;
extern fn mc_irq_wait(s: IrqEnabled) -> IrqPending;
extern fn mc_irq_ack(s: IrqPending) -> IrqEnabled;
extern fn mc_irq_release(s: IrqMasked) -> void;

// The IrqOff capability: a witness that interrupts are off.
extern fn irq_save() -> IrqOff;
extern fn irq_restore(w: IrqOff) -> void;
extern fn touch_shared(w: *IrqOff, value: u32) -> void;

// Service one interrupt, each transition in the only legal state.
export fn serve(line: u32) -> void {
    let masked: IrqMasked = mc_irq_register(line);
    let enabled: IrqEnabled = mc_irq_unmask(masked);
    let pending: IrqPending = mc_irq_wait(enabled);
    let live: IrqEnabled = mc_irq_ack(pending);
    let off: IrqMasked = mc_irq_mask(live);
    mc_irq_release(off);
}

// A critical section: the shared update is only reachable with the witness, which
// is consumed (interrupts re-enabled) on restore.
export fn critical_update(value: u32) -> void {
    let w: IrqOff = irq_save();
    touch_shared(&w, value);
    irq_restore(w);
}

// what the types forbid:
//   mc_irq_ack(enabled)   // E_NO_IMPLICIT_CONVERSION: ack wants IrqPending, not IrqEnabled
//   touch_shared(...)     // impossible without an IrqOff witness to borrow
