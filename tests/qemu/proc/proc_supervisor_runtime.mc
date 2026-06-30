// Bare-metal riscv64 M-mode test entry for the running supervisor-loop demo
// (tests/qemu/proc/proc_supervisor_demo.mc) -- in PURE MC (no C). Mirrors
// heartbeat_runtime.mc: `_start` and `mc_halt` come from the shared M-mode bring-up
// runtime (context_runtime.c, linked beside this object), and `_start` calls the
// `test_main` exported here.
//
// The demo is pure supervision/scheduling logic (no timer, no context switches), so this
// runtime just invokes it and halts; the demo itself prints SUPERVISOR-SCAN-OK and
// SUPERVISOR-LOOP-OK over the bare 16550 UART when its assertions hold.

import "tests/qemu/lib/test_report.mc";

// Defined in the shared M-mode bring-up runtime (context_runtime.c).
extern fn mc_halt() -> void;

// The supervisor-loop demo (tests/qemu/proc/proc_supervisor_demo.mc): drives
// proc_supervisor_scan across several ticks over three spawned processes and returns 1
// once every scan verdict + restart-budget assertion holds.
extern fn proc_supervisor_run() -> u32;

export fn test_main() -> void {
    uputs("proc-supervisor booting\n");
    if proc_supervisor_run() != 1 {
        uputs("SUPERVISOR-FAIL\n");
    }
    mc_halt();
}
