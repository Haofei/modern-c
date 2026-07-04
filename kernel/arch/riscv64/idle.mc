// kernel/arch/riscv64/idle — the RISC-V CPU idle action (`wfi`) packaged as a function plus an
// installer, so a platform wires it into the process table right after proc_table_init. With
// it installed, the scheduler sleeps until an interrupt when nothing is runnable instead of
// busy-spinning a blocked process (kernel/core/process keeps the mechanism, this is the arch
// policy — process.mc stays host-portable and references no asm).

import "kernel/core/process.mc";
import "kernel/arch/riscv64/csr.mc";

fn arch_idle() -> void {
    wait_for_interrupt(); // wfi: sleep until the next interrupt
}

// Install the wfi idle hook into `t` (call once, after proc_table_init).
export fn install_idle(t: *mut ProcTable) -> void {
    proc_set_idle(t, arch_idle);
}
