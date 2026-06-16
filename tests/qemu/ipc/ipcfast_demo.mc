// P2.1: IPC fast path for hot channels. ipc_fast_send (proc_ipc.mc) is the streamlined,
// provenance-skipped send for a channel the caller has designated "hot": it delivers with the
// SAME semantics as the normal ipc_try_send (same mailbox post, same wake, same success result)
// but WITHOUT the per-message provenance emit — the observability/fast-path co-design lever.
//
// This fixture, with provenance ENABLED (sample=1, so every candidate is recorded), proves the
// two paths deliver identically yet differ only in observability:
//   1. a NORMAL ipc_try_send A->B is delivered (B receives it) AND records one trace event;
//   2. after reset/drain, an ipc_fast_send A->B is delivered identically (B receives it) BUT
//      records NO trace event (the fast path skipped provenance).
// It drains B's mailbox between sends so the bounded mailbox (IPC_SLOTS=4) never blocks.
import "kernel/core/process.mc";
import "kernel/core/proc_ipc.mc";
import "kernel/core/ipc.mc";
import "kernel/core/ipc_trace.mc";

global g_t: ProcTable;
fn worker() -> void {}

const TAG_NORMAL: u32 = 0x55;
const TAG_FAST: u32 = 0x66;

export fn ipcfast_run() -> u32 {
    var pass: u32 = 1;
    proc_table_init(&g_t);
    ipc_provenance_init();
    ipc_provenance_set_enabled(true);
    ipc_provenance_set_sample(1); // record every candidate message

    // Spawn two workers: A (pid 1) sends, B (pid 2) receives.
    let a: u32 = proc_spawn(&g_t, 0x1000, worker);
    let b: u32 = proc_spawn(&g_t, 0x2000, worker);
    if a != 1 { pass = 0; }
    if b != 2 { pass = 0; }

    // A may send to B; make A the current sender so `from` is A's pid.
    proc_set_allow_mask(&g_t, a, 1 << b);
    g_t.current = a as usize;

    let tr: *mut IpcTrace = ipc_provenance();

    // ---- (1) NORMAL send: delivered AND one provenance event recorded ----
    if !ipc_try_send(&g_t, b, TAG_NORMAL, 0xAA, 0, 0) { pass = 0; }
    if ipc_trace_len(tr) != 1 { pass = 0; } // the normal path recorded exactly one event

    // B receives it (delivered identically): drain B's mailbox and check tag/payload.
    g_t.current = b as usize;
    var got1: Message = .{ .from = 0, .from_gen = 0, .call_id = 0, .tag = 0, .a0 = 0, .a1 = 0, .a2 = 0 };
    if !ipc_receive_timeout(&g_t, &got1, 0) { pass = 0; } // B got the normal message
    if got1.tag != TAG_NORMAL { pass = 0; }
    if got1.a0 != 0xAA { pass = 0; }
    if got1.from != a { pass = 0; }

    // Reset the trace so the next assertion starts clean.
    ipc_provenance_init();
    if ipc_trace_len(tr) != 0 { pass = 0; }

    // ---- (2) FAST send: delivered identically BUT no provenance event recorded ----
    g_t.current = a as usize;
    if !ipc_fast_send(&g_t, b, TAG_FAST, 0xBB, 0, 0) { pass = 0; } // same success outcome
    if ipc_trace_len(tr) != 0 { pass = 0; } // fast path skipped provenance — nothing recorded

    // B receives the fast message identically.
    g_t.current = b as usize;
    var got2: Message = .{ .from = 0, .from_gen = 0, .call_id = 0, .tag = 0, .a0 = 0, .a1 = 0, .a2 = 0 };
    if !ipc_receive_timeout(&g_t, &got2, 0) { pass = 0; } // B got the fast message too
    if got2.tag != TAG_FAST { pass = 0; }
    if got2.a0 != 0xBB { pass = 0; }
    if got2.from != a { pass = 0; }

    // Still nothing recorded after the fast delivery completed.
    if ipc_trace_len(tr) != 0 { pass = 0; }

    return pass;
}
