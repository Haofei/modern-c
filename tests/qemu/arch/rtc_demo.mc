// Wall-clock via the QEMU goldfish-RTC at 0x101000 (RTC_TIME_LOW). Reading it latches
// the host time; we expose the low 32 bits of the nanosecond counter.
import "std/addr.mc";
const RTC_BASE: usize = 0x10_1000;
export fn rtc_time_low() -> u32 {
    var v: u32 = 0;
    unsafe {
        v = raw.load<u32>(phys(RTC_BASE));
    }
    return v;
}
