// std/seqlock — a sequence lock (spec §28 planned extension) for read-mostly data, built on the
// fair ticket `Spinlock` plus an atomic sequence counter.
//
// A reader takes no lock: it snapshots the sequence before reading and checks it after, retrying
// if a write overlapped. A writer increments the sequence to odd on entry (signalling "write in
// progress") and back to even on exit; the embedded gate spinlock serializes writers so two
// writers cannot corrupt the sequence. This makes reads cheap and wait-free in the common case
// (no contention) at the cost of an occasional reader retry. Zero-initialized storage is valid.
//
// Reader pattern:
//   let s = seq_read_begin(sl);
//   ... copy the protected fields ...
//   if seq_read_retry(sl, s) { /* a write overlapped — read again */ }

import "std/spinlock.mc";

struct SeqLock {
    gate: Spinlock,    // serializes writers (readers never touch it)
    seq: atomic<u32>,  // even = stable, odd = a write is in progress
}

export fn seqlock_init(s: *mut SeqLock) -> void {
    spinlock_init(&s.gate);
    s.seq.store(0, .release);
}

// Begin a write: take the gate (excluding other writers) and bump the sequence to odd.
export fn seq_write_begin(s: *mut SeqLock) -> void {
    spin_lock(&s.gate);
    let cur: u32 = s.seq.load(.acquire);
    s.seq.store(cur + 1, .release);   // now odd: write in progress
}

// End a write: bump the sequence back to even and release the gate.
export fn seq_write_end(s: *mut SeqLock) -> void {
    let cur: u32 = s.seq.load(.acquire);
    s.seq.store(cur + 1, .release);   // now even: stable again
    spin_unlock(&s.gate);
}

// Snapshot the sequence for a read, spinning until no write is in progress (even sequence).
export fn seq_read_begin(s: *mut SeqLock) -> u32 {
    var v: u32 = s.seq.load(.acquire);
    var in_progress: bool = (v & 1) != 0;
    while in_progress {
        v = s.seq.load(.acquire);
        in_progress = (v & 1) != 0;
    }
    return v;
}

// True if a write started/finished since `start` was taken — the read must be retried.
export fn seq_read_retry(s: *mut SeqLock, start: u32) -> bool {
    let cur: u32 = s.seq.load(.acquire);
    return cur != start;
}
