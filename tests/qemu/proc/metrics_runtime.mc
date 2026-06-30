// Bare-metal riscv64 test entry for the metrics + deterministic-replay demo
// (tests/qemu/proc/metrics_demo.mc) — in PURE MC (no C). The demo is pure logic
// (no timer/trap wiring), so this entry just runs it and reports the pass code; the
// demo itself prints the REPLAY-OK / METRICS-OK / METRICS-REPLAY-OK markers.
//
// `_start`, the UART, and `mc_halt` come from the shared M-mode bring-up runtime
// (tests/qemu/proc/context_runtime.mc, linked beside this object).

import "tests/qemu/lib/test_report.mc";

extern fn mc_halt() -> void;

// The metrics demo (tests/qemu/proc/metrics_demo.mc): drives a fixed event mix
// through a live Metrics + EventLog, replays the log into a fresh Metrics and
// asserts byte-identical counters, and checks counter totals + the bounded-log
// invariant. Returns 1 on full pass.
extern fn metrics_demo_run() -> u32;

export fn test_main() -> void {
    uputs("metrics booting\n");
    let pass: u32 = metrics_demo_run();
    uputs("\nMETRICS-RC ");
    uputc((48 + (pass % 10)) as u8);
    uputc(10); // '\n'
    mc_halt();
}
