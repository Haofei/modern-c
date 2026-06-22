// kernel/lib/record — a first-cut durable recorder for the IPC provenance event stream.
//
// P3.1 (deterministic record, first cut). Full deterministic replay — re-running an agent
// with the SAME scheduling order and the SAME external inputs — is future work and NOT what
// this module does. The tractable first cut, which this module IS, is to capture the ordered
// IPC provenance event stream (the `IpcEvent`s an `IpcTrace` ring accumulates) into a
// single durable, replayable log blob in the `BlobStore`. It persists *what happened, in
// causal order*; it does not yet persist *enough to re-execute* (no thread interleavings, no
// syscall/IO inputs, no register/memory state). That deterministic re-execution substrate is
// the future; this is the provenance-log foundation the replay reader (P3.2) iterates over.
//
// HOW: `record_capture` DRAINS the trace ring oldest-first (consuming it, exactly like a
// drainer service would) and stages the popped `IpcEvent`s, in order, into one contiguous
// framed buffer, then writes that buffer as a single durable blob. `record_count` /
// `record_get` read the framed blob back — count first, then the i-th event oldest-first —
// the foundation the replay reader iterates.
//
// BLOB LAYOUT (a single framed byte run, all sub-regions copied verbatim as raw struct bytes,
// the same backend-independent raw-struct-byte approach kernel/lib/checkpoint uses):
//
//     offset                  size                       contents
//     ------                  ----                       --------
//     0                       sizeof(usize)              count: number of recorded events
//     sizeof(usize)           count * sizeof(IpcEvent) the events, oldest-first, verbatim
//
// The staging frame (RecFrame) is sized to hold the whole ring (REC_CAP events — the trace
// ring's capacity, the maximum that can ever be drained at once), so the entire log is one
// blob_put / one blob_get. Because save and read go through the identical byte layout the
// round-trip is exact and backend-independent — no field-by-field encoding, no padding
// interpretation.

import "std/addr.mc";
import "std/mem.mc";
import "kernel/core/ipc_trace.mc";
import "kernel/fs/blobstore.mc";

// Staging capacity for the framed log. The IpcTrace ring holds at most IPC_TRACE_CAP live events
// (16, module-private to ipc_trace.mc — kept in sync here), which bounds how many a single
// drain can yield, so a frame this size always holds a full capture.
const REC_CAP: usize = 16;

enum RecError {
    PutFailed,  // the BlobStore refused the write (directory Full / arena TooLarge)
    GetFailed,  // the BlobStore read back fewer bytes than the framed log needs (corrupt/short)
    NotFound,   // no recorded log blob with that id
    OutOfRange, // requested event index i >= the recorded count
    Done,       // replay cursor reached end-of-stream: no more events to play back (typed EOS)
}

// The framed log, staged contiguously: a count word then the events oldest-first. Laid out as
// fields (not a flat byte array) so the events sub-region is naturally aligned and the struct's
// own size bounds the frame. capture copies drained events in then blob_puts; the readers
// blob_get into a frame then index it. Only the first `count` events are live.
struct RecFrame {
    count: usize,
    events: [REC_CAP]IpcEvent,
}

// The exact framed length for `count` events: the count word plus that many events. A short
// capture writes (and a reader needs) only this prefix of the staging frame, so the blob never
// carries dead trailing slots.
fn rec_frame_len(count: usize) -> usize {
    return sizeof(usize) + (count * sizeof(IpcEvent));
}

// Drain `trace` oldest-first and serialize the ordered events into durable blob `id`, returning
// the number of events recorded. This CONSUMES the trace ring (a drainer's consuming read), so a
// captured log reflects exactly the events that were live at capture time, in causal order.
// PutFailed on any BlobStore rejection (never a partial write — blob_put fails closed). An empty
// ring records a valid zero-event log (count 0).
export fn record_capture(trace: *mut IpcTrace, store: *mut BlobStore, id: u32) -> Result<usize, RecError> {
    var frame: RecFrame = uninit;
    var n: usize = 0;

    // Pop oldest-first until the ring is empty (or we have filled the frame, which cannot be
    // exceeded since REC_CAP bounds the live ring). Each popped event lands at the next slot.
    var draining: bool = true;
    while draining {
        if n >= REC_CAP {
            draining = false;
        } else {
            switch ipc_trace_drain(trace) {
                ok(e) => {
                    frame.events[n] = e;
                    n = n + 1;
                }
                err(x) => { draining = false; }
            }
        }
    }
    frame.count = n;

    let frame_len: usize = rec_frame_len(n);
    switch blob_put(store, id, pa((&frame) as usize), frame_len) {
        ok(m) => { return ok(n); }
        err(e) => { return err(.PutFailed); }
    }
}

// How many events the recorded log under `id` holds. Reads just the framed count back.
// NotFound if `id` was never recorded; GetFailed if the blob is shorter than the count word.
export fn record_count(store: *mut BlobStore, id: u32) -> Result<usize, RecError> {
    var frame: RecFrame = uninit;
    let need: usize = sizeof(usize); // only the count word is required to answer this
    switch blob_get(store, id, pa((&frame) as usize), need) {
        ok(m) => {
            if m < need { return err(.GetFailed); }
            return ok(frame.count);
        }
        err(e) => { return err(.NotFound); }
    }
}

// Read the i-th recorded event back (oldest-first, i in 0..count) from the log under `id`.
// Reads the framed log, range-checks `i` against the stored count, and returns that event
// verbatim. NotFound if `id` was never recorded; GetFailed on a short/corrupt blob; OutOfRange
// if `i` is past the recorded count. This is the read the replay reader (P3.2) iterates to walk
// the persisted provenance stream in causal order.
export fn record_get(store: *mut BlobStore, id: u32, i: usize) -> Result<IpcEvent, RecError> {
    var frame: RecFrame = uninit;

    // First read just the count word so we know how much of the frame is live, then validate.
    let head: usize = sizeof(usize);
    switch blob_get(store, id, pa((&frame) as usize), head) {
        ok(m) => { if m < head { return err(.GetFailed); } }
        err(e) => { return err(.NotFound); }
    }
    if i >= frame.count {
        return err(.OutOfRange);
    }

    // The requested index is in range: read the framed prefix that covers events 0..count and
    // return the i-th. (A second blob_get of the full live frame; idempotent, same backing bytes.)
    let frame_len: usize = rec_frame_len(frame.count);
    switch blob_get(store, id, pa((&frame) as usize), frame_len) {
        ok(m) => { if m < frame_len { return err(.GetFailed); } }
        err(e) => { return err(.NotFound); }
    }
    return ok(frame.events[i]);
}

// ─── P3.2: replay — deterministic ordered playback of the recorded event stream (first cut) ───
//
// Honest scope: this is deterministic PLAYBACK of the recorded event ORDER. A ReplayCursor walks
// the persisted provenance log (the blob `record_capture` wrote) front-to-back, handing each
// `IpcEvent` back in the exact recorded order so a consumer (a future replay-driver / debugger)
// can step the stream deterministically. Re-opening the same log yields the identical sequence —
// the cursor holds no state the log doesn't, it only reads via the existing `record_get`.
//
// What this is NOT (future work): deterministic RE-EXECUTION of the kernel against the log —
// re-driving scheduling, thread interleavings and syscall/IO inputs to reproduce a run. This
// module only replays *what happened, in causal order*; it is the foundation that substrate
// builds on, not the substrate itself.

// A read-only playback cursor over a recorded log. Holds the blob `id` and the next position to
// play; `len` is the recorded event count, snapshotted at open so `replay_remaining` is O(1) and
// the cursor needs no further metadata reads. All event reads go through `record_get`, so the
// cursor adds no new persistence path and stays consistent with the recorded bytes.
struct ReplayCursor {
    id: u32,    // the recorded log blob this cursor plays
    pos: usize, // index of the NEXT event to return (0..len), advanced by replay_next
    len: usize, // total recorded events, snapshotted at open (replay_remaining == len - pos)
}

// Open a playback cursor positioned at the first recorded event of log `id`. NotFound if no log
// was recorded under `id` (propagated from record_count). An empty (zero-event) log opens fine —
// it is simply already exhausted, so the first replay_next returns Done.
export fn replay_open(store: *mut BlobStore, id: u32) -> Result<ReplayCursor, RecError> {
    switch record_count(store, id) {
        ok(n) => {
            var c: ReplayCursor = uninit;
            c.id = id;
            c.pos = 0;
            c.len = n;
            return ok(c);
        }
        err(e) => { return err(e); } // NotFound (absent log) or GetFailed (short blob)
    }
}

// Return the next event in recorded order and advance the cursor. Yields the typed end-of-stream
// signal `Done` once the cursor has played every recorded event (pos == len) — a clean, distinct
// EOS the caller switches on rather than a sentinel value. The actual event read is delegated to
// record_get, so playback order is exactly the recorded oldest-first order.
export fn replay_next(store: *mut BlobStore, c: *mut ReplayCursor) -> Result<IpcEvent, RecError> {
    if c.pos >= c.len {
        return err(.Done); // stream exhausted: no event to hand back
    }
    switch record_get(store, c.id, c.pos) {
        ok(e) => {
            c.pos = c.pos + 1; // advance only on a successful read
            return ok(e);
        }
        err(x) => { return err(x); } // GetFailed/NotFound from a vanished/corrupt blob; pos unchanged
    }
}

// How many events remain to be played (len - pos). Decrements by one per successful replay_next;
// reaches 0 exactly when the next replay_next would signal Done. Pure cursor arithmetic — no read.
export fn replay_remaining(c: *mut ReplayCursor) -> usize {
    return c.len - c.pos;
}
