// Test wrappers around the TCP window/data-plane bookkeeping.

import "kernel/net/tcp_window.mc";

global g_win: TcpWindow;

export fn tw_init(iss: u32, irs: u32, wnd: u32) -> void {
    tcp_win_init(&g_win, iss, irs, wnd);
}
export fn tw_send_space() -> u32 {
    return tcp_win_send_space(&g_win);
}
export fn tw_on_send(len: u32) -> void {
    tcp_win_on_send(&g_win, len);
}
export fn tw_on_ack(ack: u32) -> u32 {
    return tcp_win_on_ack(&g_win, ack);
}
export fn tw_update_wnd(wnd: u32) -> void {
    tcp_win_update_wnd(&g_win, wnd);
}
export fn tw_on_recv(seq: u32, len: u32) -> u32 {
    return tcp_win_on_recv(&g_win, seq, len);
}
export fn tw_snd_una() -> u32 {
    return tcp_win_snd_una(&g_win);
}
export fn tw_snd_nxt() -> u32 {
    return tcp_win_snd_nxt(&g_win);
}
export fn tw_rcv_nxt() -> u32 {
    return tcp_win_rcv_nxt(&g_win);
}
