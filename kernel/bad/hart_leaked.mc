// EXPECT: E_RESOURCE_LEAK — a hart token is never consumed.
import "kernel/arch/riscv64/hart.mc";
fn bad(vector: usize) -> void {
    let h: Hart<TrapReady> = install_trap_vector(boot_hart(0), vector);
}
