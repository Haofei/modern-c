// Bare-metal riscv64 M-mode test entry for the soak workload (tests/qemu/proc/soak_demo.mc) —
// in PURE MC (no C). Mirrors ledger_runtime.mc / proc_supervisor_runtime.mc: `_start` and `mc_halt`
// come from the shared M-mode bring-up runtime (context_runtime.c, linked beside this object) and
// `_start` calls the `test_main` exported here.
//
// The soak is pure lifecycle/accounting logic (no timer, no context switches), so this runtime
// just runs it and reports off its pass code over the bare 16550 UART. SOAK-OK appears only after
// all iterations completed with the leak/overflow invariant intact at the end.

import "tests/qemu/lib/test_report.mc";

// Defined in the shared M-mode bring-up runtime (context_runtime.c).
extern fn mc_halt() -> void;

// The soak workload (tests/qemu/proc/soak_demo.mc): spawn/charge/supervise/reclaim/reap over many
// iterations in one boot; returns 1 iff every per-iteration + final invariant held (no leak, no trap).
extern fn soak_run() -> u32;

export fn test_main() -> void {
    uputs("soak booting\n");
    let pass: u32 = soak_run();
    if pass == 1 {
        uputs("SOAK-OK\n");
    } else {
        uputs("SOAK-FAIL\n");
    }
    mc_halt();
}
