// Bare-metal M-mode platform primitives — in PURE MC. These DEFINE the symbols
// that kernel/core/panic.mc and std/time.mc declare `extern fn` (mc_halt,
// mc_read_ticks, mc_udelay): an `export fn` lowers to its unmangled C-ABI symbol,
// so the externs resolve to these at link time. They live in their OWN compilation
// unit (this file imports neither panic.mc nor std/time.mc) so the `extern fn`
// declaration and its definition never collide inside one flattened MC module —
// the link step joins them, exactly as the old C runtime object did.
//
// On QEMU virt the tick source is the CLINT mtime MMIO (64-bit monotonic counter,
// 10 MHz — reachable directly in M-mode), and halting writes the SiFive test
// finisher.

const PLAT_MTIME: usize = 0x0200_BFF8;   // 64-bit monotonic counter @ 10 MHz
const PLAT_FINISHER: usize = 0x0010_0000;      // SiFive test finisher
const PLAT_FINISHER_HALT: u32 = 0x5555;        // power-off / end-of-run code

// The free-running CLINT mtime is a `counter<u64>` (section 5.5), matching the
// `Ticks` alias std/time.mc expects mc_read_ticks to return.
type Ticks = counter<u64>;

// Monotonic tick source (std/time.mc `extern fn mc_read_ticks`).
export fn mc_read_ticks() -> Ticks {
    var t: u64 = 0;
    unsafe { t = raw.load<u64>(phys(PLAT_MTIME)); }
    return Ticks.from(t);
}

// Busy-wait `us` microseconds against the 10 MHz CLINT mtime (std/time.mc
// `extern fn mc_udelay`).
export fn mc_udelay(us: u32) -> void {
    var now: u64 = 0;
    unsafe { now = raw.load<u64>(phys(PLAT_MTIME)); }
    let target: u64 = now + (us as u64) * 10;
    var cur: u64 = now;
    while cur < target {
        unsafe { cur = raw.load<u64>(phys(PLAT_MTIME)); }
    }
}

// Stop the machine (kernel/core/panic.mc `extern fn mc_halt`). On QEMU virt that's
// the SiFive test finisher.
export fn mc_halt() -> void {
    unsafe { raw.store<u32>(phys(PLAT_FINISHER), PLAT_FINISHER_HALT); }
    while true {}
}
