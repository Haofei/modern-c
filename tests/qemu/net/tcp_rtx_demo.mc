// Test wrappers tying the retransmit timer to the send window: sending arms the
// timer; a tick past the RTO fires it and go-back-N retransmits; a full ack disarms.

import "kernel/net/tcp_rtx.mc";
import "kernel/net/tcp_window.mc";

global g_timer: RtxTimer;
global g_win: TcpWindow;

export fn t_init(rto: u64, iss: u32, wnd: u32) -> void {
    rtx_init(&g_timer, rto);
    tcp_win_init(&g_win, iss, 0, wnd);
}

// Send `len` bytes at time `now`: advance the window and arm the timer.
export fn t_send(len: u32, now: u64) -> void {
    tcp_win_on_send(&g_win, len);
    rtx_arm(&g_timer, now);
}

// A clock tick: if the RTO elapsed, go-back-N retransmit; returns bytes resent (0 if
// the timer hasn't fired).
export fn t_tick(now: u64) -> u32 {
    if rtx_expired(&g_timer, now) {
        return tcp_win_rtx_reset(&g_win);
    }
    return 0;
}

// Process an ack; disarm the timer once everything is acknowledged.
export fn t_ack(ack: u32) -> u32 {
    let acked: u32 = tcp_win_on_ack(&g_win, ack);
    let una: u32 = tcp_win_snd_una(&g_win);
    let nxt: u32 = tcp_win_snd_nxt(&g_win);
    if una == nxt {
        rtx_disarm(&g_timer);
    }
    return acked;
}

export fn t_snd_nxt() -> u32 {
    return tcp_win_snd_nxt(&g_win);
}
export fn t_armed() -> u32 {
    if rtx_is_armed(&g_timer) {
        return 1;
    }
    return 0;
}
