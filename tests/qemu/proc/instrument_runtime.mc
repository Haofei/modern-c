// Bare-metal riscv64 M-mode test entry for the instrumented-process-table demo
// (tests/qemu/proc/instrument_demo.mc) — in PURE MC (no C). Mirrors
// proc_supervisor_runtime.mc: `_start` and `mc_halt` come from the shared M-mode bring-up runtime
// (context_runtime.mc, linked beside this object), and `_start` calls the `test_main` here.
//
// The demo drives real IPC / block-I/O / supervision ops through a ProcTable and asserts the
// ledger, metrics, and supervision-tree/lease behavior; it prints LEDGER-WIRED-OK,
// METRICS-WIRED-OK, SUPTREE-OK when each part holds. This entry runs it and, on full pass, prints
// the final INSTRUMENT-OK marker the harness greps for.

import "tests/qemu/lib/test_report.mc";

// Defined in the shared M-mode bring-up runtime (context_runtime.mc).
extern fn mc_halt() -> void;

// The instrumented-process-table demo: returns 1 iff every ledger, metrics, and supervision
// assertion held.
extern fn instrument_run() -> u32;

export fn test_main() -> void {
    uputs("instrument booting\n");
    if instrument_run() == 1 {
        uputs("INSTRUMENT-OK\n");
    } else {
        uputs("INSTRUMENT-FAIL\n");
    }
    mc_halt();
}
