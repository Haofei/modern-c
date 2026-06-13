// EXPECT: E_NO_IMPLICIT_CONVERSION — enabling interrupts before the trap vector.
import "kernel/arch/riscv64/hart.mc";
fn bad() -> void {
    let h: Hart<Boot> = boot_hart(0);
    let on: Hart<IrqsOn> = enable_interrupts(h);
    forget_unchecked(on);
}
