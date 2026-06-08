// kernel/net/tcp_window — the TCP data-plane sequence/window bookkeeping (RFC 793
// send/receive sequence variables). It tracks how much data may be sent within the
// peer's advertised window, advances on ACK, and accepts in-order received bytes.
// Sequence numbers are 32-bit modular, so all arithmetic uses the wrapping helpers
// ([[std-math]] wrapping_add/sub) — wraparound is correct, never an overflow trap.

import "std/math.mc";

struct TcpWindow {
    snd_una: u32, // oldest unacknowledged sequence number
    snd_nxt: u32, // next sequence number to send
    snd_wnd: u32, // peer's advertised receive window
    rcv_nxt: u32, // next sequence number expected to receive
}

export fn tcp_win_init(w: *mut TcpWindow, iss: u32, irs: u32, wnd: u32) -> void {
    w.snd_una = iss;
    w.snd_nxt = iss;
    w.snd_wnd = wnd;
    w.rcv_nxt = irs;
}

// Bytes sent but not yet acknowledged (modular snd_nxt - snd_una).
fn in_flight(w: *mut TcpWindow) -> u32 {
    return wrapping_sub_u32(w.snd_nxt, w.snd_una);
}

// New bytes that may be sent right now: window minus in-flight (0 if the window
// is full).
export fn tcp_win_send_space(w: *mut TcpWindow) -> u32 {
    let inflight: u32 = in_flight(w);
    if inflight >= w.snd_wnd {
        return 0;
    }
    return w.snd_wnd - inflight;
}

// Record that `len` bytes were transmitted.
export fn tcp_win_on_send(w: *mut TcpWindow, len: u32) -> void {
    w.snd_nxt = wrapping_add_u32(w.snd_nxt, len);
}

// Process an incoming ACK. Advances snd_una when the ack covers new in-flight data;
// returns the number of newly acknowledged bytes — 0 for a duplicate/old ack or one
// that acknowledges data we never sent (rejected, not trusted).
export fn tcp_win_on_ack(w: *mut TcpWindow, ack: u32) -> u32 {
    let acked: u32 = wrapping_sub_u32(ack, w.snd_una);
    let unacked: u32 = wrapping_sub_u32(w.snd_nxt, w.snd_una);
    if acked == 0 {
        return 0; // duplicate / already acknowledged
    }
    if acked > unacked {
        return 0; // acknowledges unsent data
    }
    w.snd_una = ack;
    return acked;
}

// Update the peer's advertised window (from a received segment's window field).
export fn tcp_win_update_wnd(w: *mut TcpWindow, wnd: u32) -> void {
    w.snd_wnd = wnd;
}

// Go-back-N retransmit: on a timeout, rewind snd_nxt to snd_una so every unacked byte
// is sent again. Returns the number of bytes to retransmit (0 if nothing is unacked).
export fn tcp_win_rtx_reset(w: *mut TcpWindow) -> u32 {
    let unacked: u32 = wrapping_sub_u32(w.snd_nxt, w.snd_una);
    w.snd_nxt = w.snd_una;
    return unacked;
}

// Process received data at `seq` of `len` bytes. Accepts only in-order (contiguous)
// data; returns the bytes accepted, or 0 for out-of-order / already-received data.
export fn tcp_win_on_recv(w: *mut TcpWindow, seq: u32, len: u32) -> u32 {
    if seq != w.rcv_nxt {
        return 0;
    }
    w.rcv_nxt = wrapping_add_u32(w.rcv_nxt, len);
    return len;
}

export fn tcp_win_snd_una(w: *mut TcpWindow) -> u32 {
    return w.snd_una;
}
export fn tcp_win_snd_nxt(w: *mut TcpWindow) -> u32 {
    return w.snd_nxt;
}
export fn tcp_win_rcv_nxt(w: *mut TcpWindow) -> u32 {
    return w.rcv_nxt;
}
