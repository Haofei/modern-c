// kernel/platform/qemu_virt/rtc_hw — board-specific backend for the wall-clock seam.
//
// This is the ONE place that knows the QEMU `virt` machine's goldfish-rtc MMIO block
// address (0x10_1000, confirmed against the device tree QEMU hands the guest). The
// goldfish-rtc exposes a 64-bit nanoseconds-since-the-UNIX-epoch counter across two
// 32-bit registers, with a latching read contract:
//
//   TIME_LOW  (offset 0x00) — low 32 bits; reading it LATCHES the high half.
//   TIME_HIGH (offset 0x04) — high 32 bits of the latched value.
//
// The kernel/core/time interface (rtc_time_low / rtc_time_ns / time_now_epoch) is
// board-agnostic and reaches this through the `kernel/platform/active/` seam. Like core
// time, this backend deliberately imports nothing (only the `phys`/`raw.load` builtins),
// so it flattens cleanly into the standalone time object linked into the TLS bridge
// without dragging in any std symbols.

const PLAT_RTC_BASE: usize = 0x10_1000; // goldfish-rtc MMIO base (riscv64 virt)
const PLAT_RTC_TIME_LOW: usize = 0x00;
const PLAT_RTC_TIME_HIGH: usize = 0x04;

// Low 32 bits of the nanosecond counter (reading it also LATCHES the high half).
export fn plat_rtc_read_low() -> u32 {
    var v: u32 = 0;
    unsafe {
        v = raw.load<u32>(phys(PLAT_RTC_BASE + PLAT_RTC_TIME_LOW));
    }
    return v;
}

// Full 64-bit nanoseconds-since-epoch: read LOW (latches) then HIGH, per the contract.
export fn plat_rtc_read_ns() -> u64 {
    var lo: u32 = 0;
    var hi: u32 = 0;
    unsafe {
        lo = raw.load<u32>(phys(PLAT_RTC_BASE + PLAT_RTC_TIME_LOW));
        hi = raw.load<u32>(phys(PLAT_RTC_BASE + PLAT_RTC_TIME_HIGH));
    }
    return ((hi as u64) << 32) | (lo as u64);
}
