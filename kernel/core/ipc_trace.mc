// kernel/core/ipc_trace — a bounded, non-blocking IPC provenance event ring. The kernel's
// IPC mediation path appends one `TraceEvent` per message (who sent what to whom, how big,
// in what causal order); a separate drainer service reads them back later. This is pure
// observability substrate: it records provenance WITHOUT ever blocking the producer.
//
// Co-design note for the future IPC fast path (P2.1): `ipc_trace_record` is OFF the critical
// path by construction. It is a single bounded-array write plus a few counter bumps — no
// allocation, no locking, no back-pressure. When the ring is full it does NOT stall the
// sender waiting for a drainer; it OVERWRITES the oldest event and bumps a `dropped` counter.
// Tracing must never be able to wedge IPC, so the producer's worst case is O(1) and total.
// The drainer is the slow side: it reads/pops at its own pace and tolerates loss (the
// `dropped` count tells it exactly how many provenance records it missed).
//
// Self-contained on purpose: a plain fixed array (not std/ring, whose `push` rejects when
// full — we need overwrite-oldest instead). Not wired into proc_ipc.mc yet; the emit point
// is P1.2.

// Ring capacity. Small by design — provenance is meant to be drained promptly; a deep buffer
// would just hide a slow drainer. `dropped` makes overflow observable rather than silent.
const TRACE_CAP: usize = 16;

// A single IPC provenance record. `seq` is a kernel-monotonic causal counter (assigned at
// record time, never reused), so a drainer can order/dedupe events and detect the gap left
// by an overwrite even after loss.
struct TraceEvent {
    seq: u64,  // monotonic causal sequence (assigned by record())
    from: u32, // sender pid
    to: u32,   // receiver pid
    tag: u32,  // message tag/kind (meaning is the IPC layer's)
    size: u32, // payload size in bytes
}

// The ring. `head` is the index of the OLDEST live event (the read/drain cursor); writes land
// at `(head + count) % TRACE_CAP`. `count` is the number of live events (0..TRACE_CAP).
// `next_seq` is the next causal stamp to hand out. `dropped` counts events overwritten before
// any drainer read them — pure overflow accounting, never an error to the producer.
struct IpcTrace {
    events: [TRACE_CAP]TraceEvent,
    head: usize,
    count: usize,
    next_seq: u64,
    dropped: u64,
}

// Drain-side error. The only failure a reader can hit is "nothing to read".
enum TraceError {
    Empty,
}

// Reset `t` to empty in place. Seq numbering restarts at 0 (a fresh trace has no causal
// history). Event slots are never read while `count` bounds the live region, so they need
// not be cleared.
export fn ipc_trace_init(t: *mut IpcTrace) -> void {
    t.head = 0;
    t.count = 0;
    t.next_seq = 0;
    t.dropped = 0;
}

// Number of live (un-drained) events, oldest-first addressable via `ipc_trace_get`.
export fn ipc_trace_len(t: *mut IpcTrace) -> usize {
    return t.count;
}

// How many events were overwritten (lost) before a drainer read them. Monotonic; a drainer
// compares this across drains to know exactly how much provenance it missed.
export fn ipc_trace_dropped(t: *mut IpcTrace) -> u64 {
    return t.dropped;
}

// NON-BLOCKING append — the producer side, called from the IPC mediation path. Stamps the
// event with the next monotonic `seq` (returned) and writes it at the ring's tail. If the
// ring is FULL it overwrites the oldest event in place, advances `head` past it, and bumps
// `dropped`; it NEVER blocks, allocates, or fails. This O(1) total-function shape is what
// keeps tracing off the IPC critical path (see the file header / P2.1 co-design note).
//
// Returns the seq assigned to this event (always succeeds — the seq is handed out even when
// an older event is dropped to make room).
export fn ipc_trace_record(t: *mut IpcTrace, from: u32, to: u32, tag: u32, size: u32) -> u64 {
    let seq: u64 = t.next_seq;
    let ev: TraceEvent = .{ .seq = seq, .from = from, .to = to, .tag = tag, .size = size };

    // Tail slot = head + count (mod CAP). When full, head and tail coincide: we land on the
    // oldest event and overwrite it, then advance head so it points at the new oldest.
    let slot: usize = (t.head + t.count) % TRACE_CAP;
    t.events[slot] = ev;

    if t.count == TRACE_CAP {
        // Full: we just clobbered the oldest event. Advance the read cursor and count the loss.
        t.head = (t.head + 1) % TRACE_CAP;
        t.dropped = t.dropped + 1;
    } else {
        t.count = t.count + 1;
    }

    t.next_seq = t.next_seq + 1;
    return seq;
}

// Read (peek) the i-th live event, oldest-first (i in 0..len). Does NOT remove it — for a
// drainer that wants to scan/snapshot without consuming. Empty if `i` is out of range.
export fn ipc_trace_get(t: *mut IpcTrace, i: usize) -> Result<TraceEvent, TraceError> {
    if i >= t.count {
        return err(.Empty);
    }
    let slot: usize = (t.head + i) % TRACE_CAP;
    return ok(t.events[slot]);
}

// Pop the oldest live event, removing it — the drainer's consuming read. Advances `head` and
// shrinks `count`. Empty when there is nothing to drain. A drainer loops this until Empty,
// then checks `ipc_trace_dropped` to learn how many records were lost since last time.
export fn ipc_trace_drain(t: *mut IpcTrace) -> Result<TraceEvent, TraceError> {
    if t.count == 0 {
        return err(.Empty);
    }
    let ev: TraceEvent = t.events[t.head];
    t.head = (t.head + 1) % TRACE_CAP;
    t.count = t.count - 1;
    return ok(ev);
}
