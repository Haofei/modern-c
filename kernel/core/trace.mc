// kernel/core/trace — a fixed-capacity ring buffer of trace events for kernel
// debugging/tracing.
//
// Recording is O(1) and wrap-around: the newest CAPACITY events are kept, older
// ones overwritten. Each event carries a monotonically increasing sequence number,
// so a reader can tell how many events were dropped (total recorded minus retained)
// and detect gaps. Reads are bounds-checked; this is a passive sink (no I/O), safe
// to call from any context including a trap handler.

const TRACE_CAP: usize = 64;
const TRACE_CAP_U64: u64 = 64;

struct TraceEvent {
    seq: u64,   // monotonic record number
    id: u32,    // event kind
    value: u64, // payload
}

struct TraceBuffer {
    events: [TRACE_CAP]TraceEvent,
    next: u64, // total events recorded == the seq of the next one
}

export fn trace_init(t: *mut TraceBuffer) -> void {
    t.next = 0;
}

// Record an event (id, value). Overwrites the oldest retained event when full.
export fn trace_record(t: *mut TraceBuffer, id: u32, value: u64) -> void {
    let slot: usize = (t.next % TRACE_CAP_U64) as usize;
    t.events[slot].seq = t.next;
    t.events[slot].id = id;
    t.events[slot].value = value;
    t.next = t.next + 1;
}

// Total events ever recorded (including overwritten ones).
export fn trace_total(t: *mut TraceBuffer) -> u64 {
    return t.next;
}

// Events currently retained: min(total, capacity).
export fn trace_len(t: *mut TraceBuffer) -> usize {
    if t.next < TRACE_CAP_U64 {
        return t.next as usize;
    }
    return TRACE_CAP;
}

// The seq of the oldest retained event.
fn oldest_seq(t: *mut TraceBuffer) -> u64 {
    if t.next <= TRACE_CAP_U64 {
        return 0;
    }
    return t.next - TRACE_CAP_U64;
}

// Slot of the i-th retained event (0 = oldest). Caller bounds `i` via trace_len.
fn slot_of(t: *mut TraceBuffer, i: usize) -> usize {
    let seq: u64 = oldest_seq(t) + (i as u64);
    return (seq % TRACE_CAP_U64) as usize;
}

export fn trace_seq(t: *mut TraceBuffer, i: usize) -> u64 {
    let s: usize = slot_of(t, i);
    return t.events[s].seq;
}

export fn trace_id(t: *mut TraceBuffer, i: usize) -> u32 {
    let s: usize = slot_of(t, i);
    return t.events[s].id;
}

export fn trace_value(t: *mut TraceBuffer, i: usize) -> u64 {
    let s: usize = slot_of(t, i);
    return t.events[s].value;
}
