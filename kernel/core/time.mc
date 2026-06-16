// kernel/core/time — the wall-clock seam. Real UNIX time read from the QEMU
// `-machine virt` goldfish-rtc device (MMIO), replacing the build-time epoch hack.
//
// The goldfish-rtc register block lives at 0x10_1000 in the riscv64 `virt` memory
// map (confirmed against the device tree QEMU hands the guest, and by the live
// read in tools/arch/rtc-test.sh). It exposes a 64-bit nanoseconds-since-the-UNIX-
// epoch counter across two 32-bit registers:
//
//   TIME_LOW  (offset 0x00) — low 32 bits; reading it LATCHES the high half.
//   TIME_HIGH (offset 0x04) — high 32 bits of the latched value.
//
// The hardware contract is: read LOW first (latches), then HIGH. `time_now_epoch`
// divides the nanosecond count down to whole seconds — the granularity X.509
// validity wants.
//
// FALLBACK: if the device is absent or reads back zero (a machine without the
// goldfish-rtc), the caller is expected to fall back to the documented build epoch
// (`mc_build_epoch`). The RTC is the PRIMARY source; the build epoch is only a
// safety net so TLS still has a plausible clock on RTC-less hardware.
//
// `phys` and `raw.load` are MC builtins, so this module deliberately imports
// nothing — it can be compiled to a standalone object and linked into any image
// (e.g. the TLS HTTPS-GET bridge) without dragging in std/addr's exported symbols
// and causing duplicate-symbol link errors against modules that already import it.

const RTC_BASE: usize = 0x10_1000; // goldfish-rtc MMIO base (riscv64 virt)
const RTC_TIME_LOW: usize = 0x00;
const RTC_TIME_HIGH: usize = 0x04;
const NS_PER_SEC: u64 = 1_000_000_000;

// Low 32 bits of the nanosecond counter (also latches the high half). Kept for the
// original advancing-clock smoke check.
export fn rtc_time_low() -> u32 {
    var v: u32 = 0;
    unsafe {
        v = raw.load<u32>(phys(RTC_BASE + RTC_TIME_LOW));
    }
    return v;
}

// Full 64-bit nanoseconds-since-epoch. Reads LOW (latches) then HIGH, per the
// goldfish-rtc contract.
export fn rtc_time_ns() -> u64 {
    var lo: u32 = 0;
    var hi: u32 = 0;
    unsafe {
        lo = raw.load<u32>(phys(RTC_BASE + RTC_TIME_LOW));
        hi = raw.load<u32>(phys(RTC_BASE + RTC_TIME_HIGH));
    }
    return ((hi as u64) << 32) | (lo as u64);
}

// Wall-clock UNIX time in whole seconds, read from the goldfish-rtc. Returns 0 when
// the device is absent/unpopulated, signalling the caller to use the build-epoch
// fallback.
export fn time_now_epoch() -> u64 {
    let ns: u64 = rtc_time_ns();
    return ns / NS_PER_SEC;
}
