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
// The fixed RTC register block address and the latching-read sequence live in the board
// backend (kernel/platform/<board>/rtc_hw.mc), reached here through the
// `kernel/platform/active/` seam — so this file carries no MMIO address and never needs
// editing to retarget a board. The backend imports nothing but the `phys`/`raw.load`
// builtins, preserving this module's standalone-object property: it still links into the
// TLS HTTPS-GET bridge without dragging in std/addr's symbols.
import "kernel/platform/active/rtc_hw.mc";

const NS_PER_SEC: u64 = 1_000_000_000;

// Low 32 bits of the nanosecond counter (also latches the high half). Kept for the
// original advancing-clock smoke check.
export fn rtc_time_low() -> u32 {
    return plat_rtc_read_low();
}

// Full 64-bit nanoseconds-since-epoch. Reads LOW (latches) then HIGH, per the
// goldfish-rtc contract.
export fn rtc_time_ns() -> u64 {
    return plat_rtc_read_ns();
}

// Wall-clock UNIX time in whole seconds, read from the goldfish-rtc. Returns 0 when
// the device is absent/unpopulated, signalling the caller to use the build-epoch
// fallback.
export fn time_now_epoch() -> u64 {
    let ns: u64 = rtc_time_ns();
    return ns / NS_PER_SEC;
}
