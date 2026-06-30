// Structured metrics + DETERMINISTIC REPLAY, end-to-end under QEMU.
//
// This drives a fixed sequence of events through BOTH a "live" Metrics (counters
// bumped as the system runs) AND an EventLog (the same events recorded). It then
// replays the log into a SECOND, fresh Metrics and asserts every counter is
// byte-identical to the live one — proving a recorded bounded log reconstructs the
// exact final state (determinism). It also asserts specific counter totals and that
// the log is bounded (recording past capacity fails closed, count pinned at cap).
//
// Markers printed to the bare UART (grepped by the harness):
//   REPLAY-OK          — replayed counters == live counters, byte for byte
//   METRICS-OK         — counter totals + bounded-log invariant hold
//   METRICS-REPLAY-OK  — printed only when ALL assertions passed

import "kernel/core/metrics.mc";
import "tests/qemu/lib/test_report.mc";

// Demo state lives in globals (zeroed in .bss; re-zeroed by the *_init calls below),
// the standard MC idiom for fixed-array-bearing structs in these bring-up demos.
global g_live: Metrics;
global g_replayed: Metrics;
global g_log: EventLog;
global g_full: EventLog;

// Fire one event: bump the live counter AND append the matching record to the log.
// `kind` recorded is the metric's stable ordinal, so replay is self-describing.
fn fire(live: *mut Metrics, log: *mut EventLog, id: MetricId) -> void {
    metrics_inc(live, id);
    let ord: u32 = metric_ord(id) as u32;
    let _ok: bool = evlog_record(log, ord, 0, 0);
}

// Fire the same event `n` times.
fn fire_n(live: *mut Metrics, log: *mut EventLog, id: MetricId, n: u32) -> void {
    var i: u32 = 0;
    while i < n {
        fire(live, log, id);
        i = i + 1;
    }
}

export fn metrics_demo_run() -> u32 {
    var pass: u32 = 1;

    metrics_init(&g_live);
    evlog_init(&g_log);

    // ---- run the "system": a fixed event mix, mirrored into the live Metrics + log ----
    fire_n(&g_live, &g_log, .ProcSpawn, 3);
    fire_n(&g_live, &g_log, .ProcExit, 2);
    fire_n(&g_live, &g_log, .IpcSend, 5);
    fire_n(&g_live, &g_log, .IpcRecv, 4);
    fire_n(&g_live, &g_log, .SchedPreempt, 6);
    fire_n(&g_live, &g_log, .BlkRead, 2);
    fire_n(&g_live, &g_log, .BlkWrite, 1);
    // PageFault: zero events on purpose (an untouched counter must replay to 0 too)

    let total: usize = 3 + 2 + 5 + 4 + 6 + 2 + 1;
    if evlog_count(&g_log) != total { pass = 0; }

    // ---- assert specific counter totals on the live view ----
    if metrics_get(&g_live, .ProcSpawn) != 3 { pass = 0; }
    if metrics_get(&g_live, .ProcExit) != 2 { pass = 0; }
    if metrics_get(&g_live, .IpcSend) != 5 { pass = 0; }
    if metrics_get(&g_live, .IpcRecv) != 4 { pass = 0; }
    if metrics_get(&g_live, .SchedPreempt) != 6 { pass = 0; }
    if metrics_get(&g_live, .BlkRead) != 2 { pass = 0; }
    if metrics_get(&g_live, .BlkWrite) != 1 { pass = 0; }
    if metrics_get(&g_live, .PageFault) != 0 { pass = 0; }

    // ---- DETERMINISTIC REPLAY: fold the log into a fresh Metrics, compare counters ----
    evlog_replay(&g_log, &g_replayed);

    var i: usize = 0;
    var identical: u32 = 1;
    while i < 8 {
        if g_replayed.counters[i] != g_live.counters[i] { identical = 0; }
        i = i + 1;
    }
    if identical == 1 {
        uputs("REPLAY-OK\n");
    } else {
        pass = 0;
    }

    // ---- BOUNDED log: fill a fresh log to capacity, then prove overflow fails closed ----
    evlog_init(&g_full);
    var j: u32 = 0;
    while j < 64 {
        if !evlog_record(&g_full, 0, 0, 0) { pass = 0; } // first 64 must all succeed
        j = j + 1;
    }
    if evlog_count(&g_full) != 64 { pass = 0; }
    if evlog_record(&g_full, 0, 0, 0) { pass = 0; }      // 65th must fail (bounded)
    if evlog_count(&g_full) != 64 { pass = 0; }          // count pinned at capacity

    if pass == 1 {
        uputs("METRICS-OK\n");
        uputs("METRICS-REPLAY-OK\n");
    }
    return pass;
}
