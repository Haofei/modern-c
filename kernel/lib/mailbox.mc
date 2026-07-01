// kernel/lib/mailbox — `mailbox`: a bounded message queue with a per-message source key,
// so a receiver can take the next message or filter by sender. Posting to a full mailbox
// fails (drop policy); a blocking policy is layered by the caller (yield + retry). This is
// the kernel IPC mailbox pattern without the hand-rolled slot bookkeeping.
//
// FIFO is a contiguous ring: `head` is the physical index of the OLDEST message and `count`
// messages follow it in arrival order (wrapping mod N). Post appends at the tail — O(1), no
// free-slot scan. The common `mailbox_take` pops the head — O(1), no oldest-scan. This is the
// hot IPC path (every send + receive), so both are constant-time. The filtered takes
// (`take_from` / `take_if`) may remove a message from the MIDDLE of the ring; they scan for
// the oldest match (O(count)) and then compact the ring to keep it contiguous and FIFO-ordered.

struct Mailbox<T, N> {
    msg: [N]T,
    src: [N]u32,   // source key per slot, for filtered receive
    head: usize,   // physical index of the oldest message; the ring runs head..head+count-1 (mod N)
    count: usize,
}

export fn mailbox_init(comptime T: type, comptime N: usize, m: *mut Mailbox<T, N>) -> void {
    m.head = 0;
    m.count = 0;
}

export fn mailbox_count(comptime T: type, comptime N: usize, m: *mut Mailbox<T, N>) -> usize {
    return m.count;
}
export fn mailbox_is_full(comptime T: type, comptime N: usize, m: *mut Mailbox<T, N>) -> bool {
    return m.count == N;
}

// Enqueue `message` tagged with source `src`; false if the mailbox is full (drop policy).
// O(1): append at the ring tail — no free-slot scan.
export fn mailbox_post(comptime T: type, comptime N: usize, m: *mut Mailbox<T, N>, message: T, src: u32) -> bool {
    if m.count == N {
        return false; // full
    }
    let tail: usize = (m.head + m.count) % N;
    m.msg[tail] = message;
    m.src[tail] = src;
    m.count = m.count + 1;
    return true;
}

// Remove the message at logical position `k` (0 = oldest) into `out`, preserving FIFO order
// of the remaining messages. The k older messages are shifted forward by one and the old head
// is dropped, so the ring stays contiguous. O(k) <= O(count); k=0 is the O(1) head pop.
fn take_at(comptime T: type, comptime N: usize, m: *mut Mailbox<T, N>, k: usize, out: *mut T) -> void {
    let pos: usize = (m.head + k) % N;
    out.* = m.msg[pos];
    // Shift logical [0..k) up into [1..k], overwriting the taken slot (already saved to out).
    var j: usize = k;
    while j > 0 {
        let dst: usize = (m.head + j) % N;
        let srcpos: usize = (m.head + j - 1) % N;
        m.msg[dst] = m.msg[srcpos];
        m.src[dst] = m.src[srcpos];
        j = j - 1;
    }
    m.head = (m.head + 1) % N;
    m.count = m.count - 1;
}

// Take the oldest pending message into `out`; false if the mailbox is empty. O(1) head pop.
export fn mailbox_take(comptime T: type, comptime N: usize, m: *mut Mailbox<T, N>, out: *mut T) -> bool {
    if m.count == 0 {
        return false; // empty
    }
    out.* = m.msg[m.head];
    m.head = (m.head + 1) % N;
    m.count = m.count - 1;
    return true;
}

// Take the oldest pending message from source `src`; false if none from that source.
// Scans the ring oldest-first for the first match, then compacts (O(count)).
export fn mailbox_take_from(comptime T: type, comptime N: usize, m: *mut Mailbox<T, N>, src: u32, out: *mut T) -> bool {
    var k: usize = 0;
    while k < m.count {
        let pos: usize = (m.head + k) % N;
        if m.src[pos] == src {
            take_at(T, N, m, k, out);
            return true;
        }
        k = k + 1;
    }
    return false;
}

// Take the oldest message for which `keep` returns true, leaving every other message in the
// mailbox. Lets a caller select on message *contents* (e.g. a reply's correlation id) without
// consuming unrelated messages — unlike take_from, which only filters by source key. Scans the
// ring oldest-first for the first match, then compacts (O(count)).
export fn mailbox_take_if(comptime T: type, comptime N: usize, m: *mut Mailbox<T, N>, keep: closure(*T) -> bool, out: *mut T) -> bool {
    let pred: closure(*T) -> bool = keep;
    var k: usize = 0;
    while k < m.count {
        let pos: usize = (m.head + k) % N;
        if pred(&m.msg[pos]) {
            take_at(T, N, m, k, out);
            return true;
        }
        k = k + 1;
    }
    return false; // no message currently matches
}
