// Test wrappers for TCP reassembly + go-back-N retransmit.

import "kernel/net/tcp_reasm.mc";
import "kernel/net/tcp_window.mc";

global g_reasm: Reassembler;
global g_win: TcpWindow;

// Reassembly.
export fn ra_init(irs: u32) -> void {
    reasm_init(&g_reasm, irs);
}
export fn ra_accept(seq: u32, len: u32) -> u32 {
    return reasm_accept(&g_reasm, seq, len);
}
export fn ra_rcv_nxt() -> u32 {
    return reasm_rcv_nxt(&g_reasm);
}
export fn ra_buffered() -> u32 {
    return reasm_buffered(&g_reasm) as u32;
}

// Retransmit (go-back-N over the send window).
export fn rtx_init(iss: u32, wnd: u32) -> void {
    tcp_win_init(&g_win, iss, 0, wnd);
}
export fn rtx_send(len: u32) -> void {
    tcp_win_on_send(&g_win, len);
}
export fn rtx_ack(ack: u32) -> u32 {
    return tcp_win_on_ack(&g_win, ack);
}
export fn rtx_reset() -> u32 {
    return tcp_win_rtx_reset(&g_win);
}
export fn rtx_snd_nxt() -> u32 {
    return tcp_win_snd_nxt(&g_win);
}
export fn rtx_snd_una() -> u32 {
    return tcp_win_snd_una(&g_win);
}
