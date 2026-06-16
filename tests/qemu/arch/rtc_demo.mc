// Wall-clock via the QEMU goldfish-RTC at 0x101000. The actual driver + time seam
// lives in kernel/core/time.mc; this demo just re-exports the pieces the runtime
// reads (the low word for the advancing-clock check, the full ns count, and the
// epoch seconds the TLS X.509 path now consumes).
import "kernel/core/time.mc"; // brings rtc_time_low / rtc_time_ns / time_now_epoch

export fn rtc_low() -> u32 {
    return rtc_time_low();
}

export fn rtc_ns() -> u64 {
    return rtc_time_ns();
}

export fn rtc_epoch() -> u64 {
    return time_now_epoch();
}
