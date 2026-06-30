// A RUNNING supervisor loop over a ProcTable, end-to-end under QEMU (production-readiness
// §3.1 #12 remainder). scheduler_demo.mc unit-tests the supervision PRIMITIVES in isolation
// (proc_supervise / proc_heartbeat / proc_liveness_expired / proc_restart_* /
// proc_supervise_step); this drives the running LOOP — proc_supervisor_scan — across several
// ticks over THREE real spawned processes, proving the fold-the-verdict-and-actuate path:
//
//   pid1 (healthy)     beats before every scan        -> always .None, never touched
//   pid2 (transient)   misses ONE scan within budget  -> .Restart exactly once, then recovers
//   pid3 (crash-loop)  never beats, exceeds budget     -> .Restart twice, then .GiveUp ONCE
//                                                         (unsupervised; never restarted again)
//
// This is pure scheduling/supervision logic (no timer, no context switches): proc_spawn sets up
// the table slots, simulated `now` advances the clock, and each scan's encoded summary
// (restarts low 16 / give-ups high 16) plus the per-slot restart-budget state are asserted. It
// prints SUPERVISOR-SCAN-OK once the scan verdicts hold and SUPERVISOR-LOOP-OK once the whole
// loop (including "given up exactly once, not forever") is proven; returns 1 on full pass.

import "kernel/core/process.mc";
import "kernel/core/proc_sched.mc";
import "tests/qemu/lib/test_report.mc";

const INTERVAL: u64 = 10;   // a supervised slot must beat at least every 10 ticks
const MAX_RESTARTS: u32 = 2; // crash-loop budget: a slot may be restarted at most twice

global g_t: ProcTable;
fn worker() -> void {}

export fn proc_supervisor_run() -> u32 {
    var pass: u32 = 1;
    proc_table_init(&g_t);
    let p1: u32 = proc_spawn(&g_t, 0x1000, worker); // pid 1: healthy
    let p2: u32 = proc_spawn(&g_t, 0x2000, worker); // pid 2: transient miss
    let p3: u32 = proc_spawn(&g_t, 0x3000, worker); // pid 3: crash-looper
    if p1 != 1 { pass = 0; }
    if p2 != 2 { pass = 0; }
    if p3 != 3 { pass = 0; }

    // Enroll all three under supervision from t=0 (beat at least every INTERVAL ticks).
    proc_supervise(&g_t, 1, 0, INTERVAL);
    proc_supervise(&g_t, 2, 0, INTERVAL);
    proc_supervise(&g_t, 3, 0, INTERVAL);

    // ----- Scan A @ now=15: pid1 & pid2 healthy; pid3 never beat -> Restart(pid3) -----
    proc_heartbeat(&g_t, 1, 15);
    proc_heartbeat(&g_t, 2, 15);
    let a: u32 = proc_supervisor_scan(&g_t, 15, MAX_RESTARTS);
    if proc_supervisor_scan_restarts(a) != 1 { pass = 0; } // only pid3
    if proc_supervisor_scan_giveups(a) != 0 { pass = 0; }
    if proc_liveness_expired(&g_t, 3, 15) { pass = 0; }     // pid3 re-armed at its restart -> not expired

    // ----- Scan B @ now=30: pid1 healthy; pid2 MISSES (within budget); pid3 misses again -----
    proc_heartbeat(&g_t, 1, 30);                            // pid2 deliberately does NOT beat
    let b: u32 = proc_supervisor_scan(&g_t, 30, MAX_RESTARTS);
    if proc_supervisor_scan_restarts(b) != 2 { pass = 0; }  // pid2 + pid3
    if proc_supervisor_scan_giveups(b) != 0 { pass = 0; }

    // ----- Scan C @ now=45: pid2 RECOVERS; pid3 now exceeds its budget -> GiveUp(pid3) -----
    proc_heartbeat(&g_t, 1, 45);
    proc_heartbeat(&g_t, 2, 45);                            // pid2 beats again -> healthy
    let c: u32 = proc_supervisor_scan(&g_t, 45, MAX_RESTARTS);
    if proc_supervisor_scan_restarts(c) != 0 { pass = 0; }
    if proc_supervisor_scan_giveups(c) != 1 { pass = 0; }   // pid3 given up
    if proc_liveness_expired(&g_t, 3, 10000) { pass = 0; }  // pid3 unsupervised after GiveUp -> never expired

    if pass == 1 { uputs("SUPERVISOR-SCAN-OK\n"); }

    // ----- Scan D @ now=60: steady state -- pid3 already given up, others healthy -> no action -----
    proc_heartbeat(&g_t, 1, 60);
    proc_heartbeat(&g_t, 2, 60);
    let d: u32 = proc_supervisor_scan(&g_t, 60, MAX_RESTARTS);
    if proc_supervisor_scan_restarts(d) != 0 { pass = 0; }
    if proc_supervisor_scan_giveups(d) != 0 { pass = 0; }   // given up EXACTLY once, not restarted forever

    // ----- final per-slot restart-budget state (proves the counts above) -----
    if !proc_restart_allowed(&g_t, 1, 1) { pass = 0; } // pid1 count 0 (never touched)
    if proc_restart_allowed(&g_t, 2, 1) { pass = 0; }  // pid2 count == 1 ...
    if !proc_restart_allowed(&g_t, 2, 2) { pass = 0; } // ... restarted exactly once
    if proc_restart_allowed(&g_t, 3, 2) { pass = 0; }  // pid3 count == 2 ...
    if !proc_restart_allowed(&g_t, 3, 3) { pass = 0; } // ... given up, never restarted past the budget

    if pass == 1 { uputs("SUPERVISOR-LOOP-OK\n"); }
    return pass;
}
