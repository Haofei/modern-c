// kernel/arch/riscv64/trap — the machine trap handler (called by the asm stub).
//
// The asm vector (in the runtime) saves caller state, calls `handle_trap` with
// mcause/mepc, then restores and `mret`s. Here we only need the timer interrupt:
// count the tick and rearm the comparator. Arch-specific in its mcause encoding;
// the tick bookkeeping is portable.

import "kernel/drivers/timer/clint.mc";
import "kernel/arch/riscv64/hart.mc";

// mcause for a machine timer interrupt: interrupt bit (MSB) set, exception code 7.
const MCAUSE_MACHINE_TIMER: u64 = 0x8000_0000_0000_0007;
const TICK_INTERVAL: u64 = 1_000_000; // CLINT ticks between interrupts (~0.1s)

global g_ticks: u32 = 0;

// Called from the asm trap vector. Handles the timer interrupt; other causes are
// currently ignored (return resumes the interrupted instruction via mret).
export fn handle_trap(mcause: u64, mepc: u64) -> void {
    if mcause == MCAUSE_MACHINE_TIMER {
        g_ticks = g_ticks + 1;
        timer_set_alarm(0, TICK_INTERVAL); // rearm for the next tick
    }
}

// How many timer ticks have fired so far.
export fn tick_count() -> u32 {
    return g_ticks;
}

// Arm the first timer tick (call after enabling interrupts).
export fn start_ticking() -> void {
    timer_set_alarm(0, TICK_INTERVAL);
}

// A runnable demo: drive the hart typestate (install vector → enable interrupts),
// arm the timer, and spin until `target` ticks have fired. The platform passes
// the address of its asm trap vector. Returns the observed tick count.
export fn kernel_tick_demo(trap_vector: usize, target: u32) -> u32 {
    let h0: Hart<Boot> = boot_hart(0);
    let h1: Hart<TrapReady> = install_trap_vector(h0, trap_vector);
    let h2: Hart<IrqsOn> = enable_interrupts(h1);
    start_ticking();

    var spins: u64 = 0;
    while spins < 500_000_000 {
        if tick_count() >= target {
            break;
        }
        spins = spins + 1;
    }
    drop(h2); // interrupts stay on; we just retire the typestate token
    return tick_count();
}
