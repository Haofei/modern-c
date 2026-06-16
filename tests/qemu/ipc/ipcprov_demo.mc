// P1.2: IPC provenance emission from the kernel's IPC mediation path. The send path
// (proc_ipc.mc) records one trace event per successful delivery — who sent what to whom, in
// monotonic causal order — as a PURE ADDITION that does not change delivery behavior. A
// hot-channel opt-out (ipc_provenance_set_enabled) suppresses recording without affecting
// the send result. This fixture spawns two processes, performs non-blocking A->B sends with
// distinct tags, drains the trace, and asserts (from, to, tag) match in order with monotonic
// seqs; then it disables provenance, sends again, and asserts no new event was recorded.
import "kernel/core/process.mc";
import "kernel/core/proc_ipc.mc";
import "kernel/core/ipc.mc";
import "kernel/core/ipc_trace.mc";

global g_t: ProcTable;
fn worker() -> void {}

const TAG_ONE: u32 = 0x11;
const TAG_TWO: u32 = 0x22;
const TAG_THREE: u32 = 0x33;

export fn ipcprov_run() -> u32 {
    var pass: u32 = 1;
    proc_table_init(&g_t);
    ipc_provenance_init();

    // Spawn two worker processes: A (slot/pid 1) and B (slot/pid 2).
    let a: u32 = proc_spawn(&g_t, 0x1000, worker);
    let b: u32 = proc_spawn(&g_t, 0x2000, worker);
    if a != 1 { pass = 0; }
    if b != 2 { pass = 0; }

    // Let A send to B (allow_mask bit b), and make A the current sender so `from` is A's pid.
    proc_set_allow_mask(&g_t, a, 1 << b);
    g_t.current = a as usize;

    // Two non-blocking A->B sends with distinct tags; both must be delivered.
    if !ipc_try_send(&g_t, b, TAG_ONE, 0, 0, 0) { pass = 0; }
    if !ipc_try_send(&g_t, b, TAG_TWO, 0, 0, 0) { pass = 0; }

    // The trace must hold exactly the two events, oldest-first, with monotonic seqs.
    let tr: *mut IpcTrace = ipc_provenance();
    if ipc_trace_len(tr) != 2 { pass = 0; }

    var prev_seq: u64 = 0;
    var have_prev: bool = false;

    switch ipc_trace_drain(tr) {
        ok(ev1) => {
            if ev1.from != a { pass = 0; }
            if ev1.to != b { pass = 0; }
            if ev1.tag != TAG_ONE { pass = 0; }
            prev_seq = ev1.seq;
            have_prev = true;
        }
        err(e1) => { pass = 0; }
    }
    switch ipc_trace_drain(tr) {
        ok(ev2) => {
            if ev2.from != a { pass = 0; }
            if ev2.to != b { pass = 0; }
            if ev2.tag != TAG_TWO { pass = 0; }
            if !have_prev { pass = 0; }
            if ev2.seq <= prev_seq { pass = 0; } // strictly monotonic
        }
        err(e2) => { pass = 0; }
    }

    // Drained dry.
    if ipc_trace_len(tr) != 0 { pass = 0; }
    switch ipc_trace_drain(tr) {
        ok(ev3) => { pass = 0; }
        err(e3) => {}
    }

    // ---- hot-channel opt-out: disabling provenance suppresses recording ----
    ipc_provenance_set_enabled(false);
    // The send must still succeed (delivery behavior is unchanged by the opt-out)...
    if !ipc_try_send(&g_t, b, TAG_THREE, 0, 0, 0) { pass = 0; }
    // ...but no new event was recorded.
    if ipc_trace_len(tr) != 0 { pass = 0; }

    // Re-enabling resumes recording (proves the toggle is the only gate).
    ipc_provenance_set_enabled(true);
    if !ipc_try_send(&g_t, b, TAG_THREE, 0, 0, 0) { pass = 0; }
    if ipc_trace_len(tr) != 1 { pass = 0; }
    switch ipc_trace_drain(tr) {
        ok(ev4) => {
            if ev4.from != a { pass = 0; }
            if ev4.to != b { pass = 0; }
            if ev4.tag != TAG_THREE { pass = 0; }
        }
        err(e4) => { pass = 0; }
    }

    return pass;
}
