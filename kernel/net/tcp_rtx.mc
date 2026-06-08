// kernel/net/tcp_rtx — the TCP retransmission timer. Armed when unacknowledged data
// is outstanding; it fires once the retransmit timeout (RTO) elapses, prompting a
// go-back-N retransmit (tcp_win_rtx_reset), and disarms when everything is acked.
// Time is passed in as a tick count (the caller supplies read_ticks()), so the logic
// is pure and testable with a simulated clock.

struct RtxTimer {
    deadline: u64, // tick at which to retransmit (valid when armed)
    rto: u64,      // retransmit timeout, in ticks
    armed: bool,
}

export fn rtx_init(t: *mut RtxTimer, rto: u64) -> void {
    t.rto = rto;
    t.deadline = 0;
    t.armed = false;
}

// Arm the timer because unacked data was sent; fires at now + RTO. No-op if already
// armed (the timer tracks the oldest unacked segment).
export fn rtx_arm(t: *mut RtxTimer, now: u64) -> void {
    let a: bool = t.armed;
    if !a {
        t.deadline = now + t.rto;
        t.armed = true;
    }
}

// Disarm the timer (all outstanding data has been acknowledged).
export fn rtx_disarm(t: *mut RtxTimer) -> void {
    t.armed = false;
}

export fn rtx_is_armed(t: *mut RtxTimer) -> bool {
    return t.armed;
}

// Has the RTO elapsed at `now`? If so, re-arm for the next interval and return true
// (the caller retransmits). False if disarmed or not yet due.
export fn rtx_expired(t: *mut RtxTimer, now: u64) -> bool {
    let a: bool = t.armed;
    if !a {
        return false;
    }
    if now >= t.deadline {
        t.deadline = now + t.rto; // re-arm for the retransmitted data
        return true;
    }
    return false;
}
