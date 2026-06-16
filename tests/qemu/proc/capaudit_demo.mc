// Capability-use audit (P1.3). Where the IPC trace records messages, the cap-use audit
// records *authority use*: every kcall invocation (a process exercising its kcall_mask to
// invoke a kernel op) is appended to a DEDICATED trace, disjoint from proc_ipc's g_ipc_trace.
//
// This driver-mode fixture (host: arch context primitives stubbed by the C driver) checks:
//   * kcall records one event per invocation, carrying caller pid (from) + op (tag), in order;
//   * recording happens REGARDLESS of the permission decision — the audit hook runs before the
//     kcall_mask check, so both allowed and denied invocations are captured (the point of an
//     audit is to see attempts to exercise authority, not just the ones that succeeded);
//   * cap_audit_set_enabled(false) makes kcall stop emitting events (observe-only opt-out),
//     without changing kcall's return value.

import "kernel/core/process.mc";
import "kernel/core/ipc_trace.mc";
import "std/mask.mc";

global g_t: ProcTable;

export fn capaudit_run() -> u32 {
    var pass: u32 = 1;
    proc_table_init(&g_t);
    cap_audit_init();

    // Bootstrap is pid 0 (the current process). Grant it a kcall_mask permitting ops {1,3}
    // (bits 1 and 3 set -> 0b1010 = 10). Op 2 is deliberately NOT permitted -> a denied
    // invocation we still audit.
    let allow_bits: u32 = 10;
    proc_set_kcall_mask(&g_t, 0, allow_bits);

    // Invoke kcall a few times with distinct ops: op 1 (allowed), op 2 (denied), op 3 (allowed).
    // The record happens for ALL of them (hook is before the mask check); the return value still
    // reflects the permission decision.
    switch kcall(&g_t, 1, 100) { ok(v) => { if v != 100 { pass = 0; } } err(e) => { pass = 0; } }
    switch kcall(&g_t, 2, 200) { ok(v) => { pass = 0; } err(e) => {} }   // denied, but still audited
    switch kcall(&g_t, 3, 300) { ok(v) => { if v != 300 { pass = 0; } } err(e) => { pass = 0; } }

    // Drain the DEDICATED cap-use trace: exactly three events, caller pid 0, op tags 1,2,3 in order.
    let aud: *mut IpcTrace = cap_audit();
    if ipc_trace_len(aud) != 3 { pass = 0; }

    let expect_ops: [3]u32 = .{ 1, 2, 3 };
    var i: usize = 0;
    while i < 3 {
        switch ipc_trace_drain(aud) {
            ok(ev) => {
                if ev.from != 0 { pass = 0; }            // caller pid
                if ev.tag != expect_ops[i] { pass = 0; } // op
                if ev.to != 0 { pass = 0; }
                if ev.size != 0 { pass = 0; }
            }
            err(e) => { pass = 0; }
        }
        i = i + 1;
    }
    // Drained dry.
    if ipc_trace_len(aud) != 0 { pass = 0; }

    // Opt out: with the audit disabled, kcall still works but emits no new events.
    cap_audit_set_enabled(false);
    switch kcall(&g_t, 1, 400) { ok(v) => { if v != 400 { pass = 0; } } err(e) => { pass = 0; } }
    if ipc_trace_len(aud) != 0 { pass = 0; } // no event recorded while disabled

    return pass;
}
