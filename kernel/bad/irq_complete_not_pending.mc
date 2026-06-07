// EXPECT: E_NO_IMPLICIT_CONVERSION — completing an IRQ that was never claimed.
import "kernel/drivers/irq/plic.mc";
fn bad(base: usize) -> void {
    let l: IrqLine<Enabled> = enable(base, claim_line(9));
    let l2: IrqLine<Enabled> = complete(base, l); // complete wants Pending, got Enabled
    release(base, l2);
}
