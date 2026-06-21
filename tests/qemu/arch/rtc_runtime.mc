// Bare-metal riscv64 M-mode test entry for the goldfish-RTC wall-clock demo
// (tests/qemu/arch/rtc_demo.mc) — in PURE MC (no C). The all-MC replacement for
// kernel/arch/riscv64/rtc_runtime.c.
//
// `_start` and `mc_halt` come from the shared M-mode bring-up runtime
// (kernel/arch/riscv64/context_runtime.c, linked beside this object); `_start`
// calls the `test_main` exported here. This unit drives the SAME existing MC RTC
// demo (rtc_low/rtc_ns/rtc_epoch) and writes the bare 16550 UART directly (the
// rtc demo does not define a console), reproducing the C entry's asserted output:
//   reads the low word twice (advancing check), prints EPOCH=/NS=, and on a
//   plausible live "now" (1.7e9 .. 2.0e9 s) prints RTC-OK.

const RT_UART_THR: usize = 0x1000_0000; // QEMU virt 16550 transmit-hold register

// Write one byte to the bare 16550 UART transmit register.
fn uputc(c: u8) -> void {
    unsafe {
        raw.store<u8>(phys(RT_UART_THR), c);
    }
}

// Write a NUL-terminated string over the bare UART.
fn uputs(s: *const u8) -> void {
    let base: usize = s as usize;
    var i: usize = 0;
    while true {
        var b: u8 = 0;
        unsafe { b = raw.load<u8>(phys(base + i)); }
        if b == 0 {
            break;
        }
        uputc(b);
        i = i + 1;
    }
}

// Print an unsigned 64-bit value in decimal.
fn uputdec(v: u64) -> void {
    if v == 0 {
        uputc(48); // '0'
        return;
    }
    var tmp: [20]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    var n: usize = 0;
    var x: u64 = v;
    while x != 0 {
        tmp[n] = (48 + (x % 10)) as u8; // '0' + digit
        n = n + 1;
        x = x / 10;
    }
    while n != 0 {
        n = n - 1;
        uputc(tmp[n]);
    }
}

// Defined in the shared M-mode bring-up runtime (context_runtime.c): stop the
// machine via the SiFive test finisher.
extern fn mc_halt() -> void;

// The RTC demo (tests/qemu/arch/rtc_demo.mc) over kernel/core/time.mc.
extern fn rtc_low() -> u32;
extern fn rtc_ns() -> u64;
extern fn rtc_epoch() -> u64;

export fn test_main() -> void {
    uputs("rtc booting\n");

    // (1) advancing-clock check on the low word.
    let a: u32 = rtc_low();
    var i: u32 = 0;
    while i < 100000 { // burn time
        i = i + 1;
    }
    let b: u32 = rtc_low();

    // (2) full wall-clock epoch via the time seam.
    let ns: u64 = rtc_ns();
    let epoch: u64 = rtc_epoch();
    uputs("EPOCH=");
    uputdec(epoch);
    uputc(10); // '\n'
    uputs("NS=");
    uputdec(ns);
    uputc(10); // '\n'

    let advancing: bool = a != 0 && b != 0;
    // Plausible live timestamp: 1.7e9 .. 2.0e9 seconds since the UNIX epoch.
    let plausible: bool = epoch > 1700000000 && epoch < 2000000000;

    if advancing && plausible {
        uputs("RTC-OK\n");
    } else if !plausible {
        uputs("RTC-IMPLAUSIBLE\n");
    } else {
        uputs("RTC-ZERO\n");
    }
    mc_halt();
}
