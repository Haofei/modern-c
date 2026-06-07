// kernel/drivers/timer/clint — RISC-V CLINT machine timer. Reads `mtime` and arms
// `mtimecmp` to schedule the next timer interrupt. Stateless MMIO (no typestate);
// the interrupt it raises is handled through the IRQ/trap path. An ARM port swaps
// this for the generic timer (CNTP_*) behind the same two functions.

const CLINT_MTIME: usize = 0x0200_BFF8;    // 64-bit monotonic counter
const CLINT_MTIMECMP: usize = 0x0200_4000; // + 8*hart: compare for the next IRQ

// The current monotonic tick count.
export fn timer_now() -> u64 {
    unsafe {
        return raw.load<u64>(phys(CLINT_MTIME));
    }
}

// Arm the timer to fire `delta` ticks from now for `hart`.
export fn timer_set_alarm(hart: u32, delta: u64) -> void {
    let target: u64 = timer_now() + delta;
    unsafe {
        raw.store<u64>(phys(CLINT_MTIMECMP + (hart as usize) * 8), target);
    }
}
