// P1.4: IPC provenance sampling — the fast-path lever. On a hot channel, recording one trace
// event per message is too costly; sampling records only 1 of every N messages so provenance
// stays cheap while still observing a representative fraction. It is deterministic (a counter
// selects when (counter % N) == 0, restarted by set_sample) so it is exactly testable, and it
// is observe-only: delivery behavior never changes regardless of the sample rate.
//
// This fixture, A->B over a ProcTable:
//   - set_sample(1): send 5 messages -> 5 recorded (every message), seqs monotonic.
//   - reset trace, set_sample(3): send 9 -> exactly 3 recorded (the 1st, 4th, 7th), monotonic.
//   - set_sample(0): send -> 0 recorded (opt-out, equivalent to disabled), delivery still ok.
import "kernel/core/process.mc";
import "kernel/core/proc_ipc.mc";
import "kernel/core/ipc.mc";
import "kernel/core/ipc_trace.mc";

global g_t: ProcTable;
fn worker() -> void {}

const TAG_X: u32 = 0x55;

// Drain the trace fully, asserting monotonic seqs; returns the number of events drained, or a
// huge sentinel on a non-monotonic seq so the caller fails.
fn drain_count(tr: *mut IpcTrace) -> u32 {
    var n: u32 = 0;
    var prev_seq: u64 = 0;
    var have_prev: bool = false;
    var draining: bool = true;
    while draining {
        switch ipc_trace_drain(tr) {
            ok(ev) => {
                if have_prev {
                    if ev.seq <= prev_seq { return 0xFFFFFFFF; } // not strictly monotonic
                }
                prev_seq = ev.seq;
                have_prev = true;
                n = n + 1;
            }
            err(e) => { draining = false; }
        }
    }
    return n;
}

// Send one A->B message (A is current, so provenance records from=A), then immediately drain
// B's mailbox so a long run of sends never fills B's bounded inbox (IPC_SLOTS). Provenance is
// recorded at send time against the current sender (A); the post-send drain as B is just to
// keep the mailbox from backing up and does not change what was recorded. Returns send success.
fn send_and_drain(a: u32, b: u32) -> bool {
    let ok_sent: bool = ipc_try_send(&g_t, b, TAG_X, 0, 0, 0);
    // Drain the just-delivered message out of B's inbox (receive reads the *current* proc's
    // inbox, so switch current to B for the drain, then restore A as the sender). With a 0-yield
    // timeout this is a single non-blocking take; it must find the message we just delivered.
    g_t.current = b as usize;
    var m: Message = .{ .from = 0, .from_gen = 0, .call_id = 0, .tag = 0, .a0 = 0, .a1 = 0, .a2 = 0 };
    let drained: bool = ipc_receive_timeout(&g_t, &m, 0);
    g_t.current = a as usize;
    return ok_sent && drained;
}

export fn ipcsample_run() -> u32 {
    var pass: u32 = 1;
    proc_table_init(&g_t);
    ipc_provenance_init();
    ipc_provenance_set_enabled(true); // provenance is OFF by default in production; this fixture exercises it

    let a: u32 = proc_spawn(&g_t, 0x1000, worker);
    let b: u32 = proc_spawn(&g_t, 0x2000, worker);
    if a != 1 { pass = 0; }
    if b != 2 { pass = 0; }

    proc_set_allow_mask(&g_t, a, 1 << b);
    g_t.current = a as usize;

    let tr: *mut IpcTrace = ipc_provenance();

    // ---- sample(1): record every message. 5 sends -> 5 recorded. ----
    ipc_provenance_set_sample(1);
    var i: u32 = 0;
    while i < 5 {
        if !send_and_drain(a, b) { pass = 0; }
        i = i + 1;
    }
    if drain_count(tr) != 5 { pass = 0; }
    if ipc_trace_len(tr) != 0 { pass = 0; }

    // ---- sample(3): record 1 of every 3. reset trace, 9 sends -> exactly 3 recorded. ----
    ipc_provenance_init(); // reset the ring
    ipc_provenance_set_sample(3);
    let tr2: *mut IpcTrace = ipc_provenance();
    i = 0;
    while i < 9 {
        if !send_and_drain(a, b) { pass = 0; }
        i = i + 1;
    }
    if drain_count(tr2) != 3 { pass = 0; }

    // ---- sample(0): record nothing (opt-out). Delivery still succeeds. ----
    ipc_provenance_set_sample(0);
    if !send_and_drain(a, b) { pass = 0; }
    if ipc_trace_len(tr2) != 0 { pass = 0; }

    return pass;
}
