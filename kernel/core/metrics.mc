// kernel/core/metrics — a small, reusable kernel METRICS + EVENT-LOG subsystem.
//
// Two cooperating primitives, both bounded and self-contained (no kernel-path
// dependencies — this module deliberately does NOT wire itself into hot paths;
// callers opt in):
//
//   1. `Metrics` — a fixed array of named u64 counters, one per `MetricId`. The
//      "live" view of how often each kind of event happened (spawns, IPC sends,
//      block reads, ...). Counters SATURATE at u64 max rather than wrapping: a
//      monotone counter that silently wraps to a tiny value is worse than one
//      pinned at the top, and checked arithmetic would otherwise TRAP on overflow.
//
//   2. `EventLog` — a fixed-capacity, append-only log of `Event{kind,a,b}`. It is
//      the DETERMINISTIC-REPLAY primitive: record the same events you fed the live
//      Metrics, and `evlog_replay` folds the whole log into a FRESH Metrics by
//      switching on each event's `kind` and incrementing the matching counter.
//      Same log => byte-identical counters, every time. Recording past capacity
//      fails closed (returns false) — it never overflows or overwrites.

// The set of things we count. Ordinals (0..METRIC_COUNT) index the counter array
// and are also the on-the-wire `Event.kind` values, so the log is self-describing.
pub enum MetricId {
    ProcSpawn,     // a process was spawned
    ProcExit,      // a process exited
    IpcSend,       // an IPC message was sent
    IpcRecv,       // an IPC message was received
    SchedPreempt,  // the scheduler preempted the running task
    BlkRead,       // a block-device read completed
    BlkWrite,      // a block-device write completed
    PageFault,     // a page fault was handled
}

const METRIC_COUNT: usize = 8;        // number of MetricId variants
const U64_MAX: u64 = 0xFFFF_FFFF_FFFF_FFFF;
const EVLOG_CAP: usize = 64;          // event-log capacity (bounded; recording past this fails)

// Stable ordinal for a MetricId (also its array index and wire `kind`).
// `#[irq_context]`: a pure switch returning a small ordinal, no blocking/indirect calls — so a
// counter update built on it (metrics_add/metrics_inc) can meter an event from an ISR path
// (e.g. proc_preempt_tick's quantum-expiry edge).
#[irq_context]
pub fn metric_ord(id: MetricId) -> usize {
    switch id {
        .ProcSpawn => { return 0; }
        .ProcExit => { return 1; }
        .IpcSend => { return 2; }
        .IpcRecv => { return 3; }
        .SchedPreempt => { return 4; }
        .BlkRead => { return 5; }
        .BlkWrite => { return 6; }
        .PageFault => { return 7; }
    }
}

pub struct Metrics {
    counters: [METRIC_COUNT]u64,
}

// Zero every counter — start of a fresh measurement (or a replay target).
pub fn metrics_init(m: *mut Metrics) -> void {
    var i: usize = 0;
    while i < METRIC_COUNT {
        m.counters[i] = 0;
        i = i + 1;
    }
}

// Add `n` to a counter, SATURATING at u64 max (checked add would trap on overflow).
// `#[irq_context]`: only a bounded array read/write plus saturating arithmetic — no blocking or
// indirect calls — so a hot-path counter can be bumped directly from an ISR (see proc_preempt_tick).
#[irq_context]
pub fn metrics_add(m: *mut Metrics, id: MetricId, n: u64) -> void {
    let i: usize = metric_ord(id);
    let cur: u64 = m.counters[i];
    // saturate: guard the add so `cur + n` can never overflow (and trap)
    if n > U64_MAX - cur {
        m.counters[i] = U64_MAX;
    } else {
        m.counters[i] = cur + n;
    }
}

// Increment a counter by one (saturating).
// `#[irq_context]`: delegates to the irq-safe metrics_add, so an ISR edge (e.g. a scheduler
// preemption) can meter itself with a single call.
#[irq_context]
pub fn metrics_inc(m: *mut Metrics, id: MetricId) -> void {
    metrics_add(m, id, 1);
}

// Read a counter's current value.
pub fn metrics_get(m: *Metrics, id: MetricId) -> u64 {
    let i: usize = metric_ord(id); // bind the ordinal first (a bare call inside the index emits an unused C pre-temp)
    return m.counters[i];
}

// One recorded event: `kind` is a MetricId ordinal; `a`/`b` are free payload slots
// (e.g. a pid and a byte count) carried for the record, not used by counter replay.
pub struct Event {
    kind: u32,
    a: u64,
    b: u64,
}

pub struct EventLog {
    items: [EVLOG_CAP]Event,
    count: usize,
}

// Empty the log.
pub fn evlog_init(l: *mut EventLog) -> void {
    l.count = 0;
}

// Append an event. Returns false (and records nothing) when the log is full — the
// log is BOUNDED and never overflows or overwrites earlier records.
pub fn evlog_record(l: *mut EventLog, kind: u32, a: u64, b: u64) -> bool {
    if l.count >= EVLOG_CAP {
        return false;
    }
    let i: usize = l.count;
    l.items[i].kind = kind;
    l.items[i].a = a;
    l.items[i].b = b;
    l.count = i + 1;
    return true;
}

// Number of events recorded so far.
pub fn evlog_count(l: *EventLog) -> usize {
    return l.count;
}

// The i-th recorded event (caller must ensure i < evlog_count).
pub fn evlog_get(l: *EventLog, i: usize) -> Event {
    return l.items[i];
}

// DETERMINISM PRIMITIVE: fold the whole log into a FRESH Metrics. Each event's
// `kind` ordinal selects a counter, which is incremented by one. Unknown kinds
// (outside the MetricId range) are skipped, so a log can never corrupt the
// reconstructed state. Same log => byte-identical counters.
pub fn evlog_replay(l: *EventLog, m: *mut Metrics) -> void {
    metrics_init(m);
    var i: usize = 0;
    let n: usize = l.count;
    while i < n {
        let k: usize = l.items[i].kind as usize;
        if k < METRIC_COUNT {
            // increment the selected counter directly (saturating)
            let cur: u64 = m.counters[k];
            if cur < U64_MAX {
                m.counters[k] = cur + 1;
            }
        }
        i = i + 1;
    }
}
