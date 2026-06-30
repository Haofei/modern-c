// Bare-metal riscv64 M-mode test entry for the unified-ledger demo
// (tests/qemu/proc/ledger_demo.mc) — in PURE MC (no C).
//
// `_start` and `mc_halt` come from the shared M-mode bring-up runtime
// (kernel/arch/riscv64/context_runtime.c, linked beside this object); `_start` calls the
// `test_main` exported here. The ledger demo is pure computation (no ProcTable / heap / timer), so
// this runtime just runs it and reports off its pass code over the bare 16550 UART.

import "tests/qemu/lib/test_report.mc";

// Defined in the shared M-mode bring-up runtime (context_runtime.c).
extern fn mc_halt() -> void;

// The unified-ledger demo (tests/qemu/proc/ledger_demo.mc): returns 1 iff every charge/release/
// overflow-edge/independence property holds.
extern fn ledger_run() -> u32;

export fn test_main() -> void {
    uputs("ledger booting\n");
    let pass: u32 = ledger_run();
    if pass == 1 {
        uputs("LEDGER-OK\n");
        uputs("UNIFIED-LEDGER-OK\n");
    } else {
        uputs("LEDGER-FAIL\n");
    }
    mc_halt();
}
