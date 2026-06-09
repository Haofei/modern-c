// MC standard library — `mailbox`: a bounded message queue with a per-message source key,
// so a receiver can take the next message or filter by sender. Posting to a full mailbox
// fails (drop policy); a blocking policy is layered by the caller (yield + retry). This is
// the kernel IPC mailbox pattern without the hand-rolled slot bookkeeping.
//
// FIFO is preserved across slot reuse via a monotonic per-slot sequence number: post into
// any free slot, but take/take_from always return the *oldest* (lowest sequence) matching
// message — so a freed-and-reused low slot index does not jump ahead of an older message.

struct Mailbox<T, N> {
    msg: [N]T,
    src: [N]u32,   // source key per slot, for filtered receive
    seq: [N]u64,   // arrival order, so the oldest is taken first (FIFO)
    valid: [N]bool,
    count: usize,
    next_seq: u64, // monotonic sequence stamp
}

export fn mailbox_init(comptime T: type, comptime N: usize, m: *mut Mailbox<T, N>) -> void {
    var i: usize = 0;
    while i < N {
        m.valid[i] = false;
        i = i + 1;
    }
    m.count = 0;
    m.next_seq = 0;
}

export fn mailbox_count(comptime T: type, comptime N: usize, m: *mut Mailbox<T, N>) -> usize {
    return m.count;
}
export fn mailbox_is_full(comptime T: type, comptime N: usize, m: *mut Mailbox<T, N>) -> bool {
    return m.count == N;
}

// Enqueue `message` tagged with source `src`; false if the mailbox is full (drop policy).
export fn mailbox_post(comptime T: type, comptime N: usize, m: *mut Mailbox<T, N>, message: T, src: u32) -> bool {
    var i: usize = 0;
    while i < N {
        if !m.valid[i] {
            m.msg[i] = message;
            m.src[i] = src;
            m.seq[i] = m.next_seq;
            m.next_seq = m.next_seq + 1;
            m.valid[i] = true;
            m.count = m.count + 1;
            return true;
        }
        i = i + 1;
    }
    return false; // full
}

// The slot index of the oldest valid message (optionally only from `src` when filtered),
// or N if none. `filtered`/`src` select between any-source and source-filtered take.
fn oldest_slot(comptime T: type, comptime N: usize, m: *mut Mailbox<T, N>, filtered: bool, src: u32) -> usize {
    var best: usize = N;
    var best_seq: u64 = 0;
    var i: usize = 0;
    while i < N {
        if m.valid[i] {
            var is_match: bool = true;
            if filtered {
                if m.src[i] != src {
                    is_match = false;
                }
            }
            if is_match {
                if best >= N {
                    best = i;
                    best_seq = m.seq[i];
                } else {
                    if m.seq[i] < best_seq {
                        best = i;
                        best_seq = m.seq[i];
                    }
                }
            }
        }
        i = i + 1;
    }
    return best;
}

fn take_slot(comptime T: type, comptime N: usize, m: *mut Mailbox<T, N>, slot: usize, out: *mut T) -> void {
    out.* = m.msg[slot];
    m.valid[slot] = false;
    m.count = m.count - 1;
}

// Take the oldest pending message into `out`; false if the mailbox is empty.
export fn mailbox_take(comptime T: type, comptime N: usize, m: *mut Mailbox<T, N>, out: *mut T) -> bool {
    let slot: usize = oldest_slot(T, N, m, false, 0);
    if slot >= N {
        return false; // empty
    }
    take_slot(T, N, m, slot, out);
    return true;
}

// Take the oldest pending message from source `src`; false if none from that source.
export fn mailbox_take_from(comptime T: type, comptime N: usize, m: *mut Mailbox<T, N>, src: u32, out: *mut T) -> bool {
    let slot: usize = oldest_slot(T, N, m, true, src);
    if slot >= N {
        return false;
    }
    take_slot(T, N, m, slot, out);
    return true;
}
