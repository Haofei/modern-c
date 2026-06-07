// EXPECT: E_NO_IMPLICIT_CONVERSION — acking an interrupt that has not fired.
import "demo/irq/irq.mc";
fn bad(line: u32) -> void {
    let m: IrqMasked = mc_irq_register(line);
    let en: IrqEnabled = mc_irq_unmask(m);
    let live: IrqEnabled = mc_irq_ack(en);
    let off: IrqMasked = mc_irq_mask(live);
    mc_irq_release(off);
}
