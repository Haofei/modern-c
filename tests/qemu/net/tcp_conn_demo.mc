// Test wrappers around the TCP state machine for the host driver: drive a global
// connection and map the state/action enums to small integer codes.

import "kernel/net/tcp_conn.mc";

global g_conn: TcpConn;

fn state_code(s: TcpState) -> u32 {
    switch s {
        .Closed => { return 0; }
        .Listen => { return 1; }
        .SynSent => { return 2; }
        .SynReceived => { return 3; }
        .Established => { return 4; }
        .FinWait1 => { return 5; }
        .FinWait2 => { return 6; }
        .CloseWait => { return 7; }
        .LastAck => { return 8; }
        .TimeWait => { return 9; }
    }
}

fn action_code(a: TcpAction) -> u32 {
    switch a {
        .None => { return 0; }
        .SendSyn => { return 1; }
        .SendSynAck => { return 2; }
        .SendAck => { return 3; }
        .SendFin => { return 4; }
    }
}

export fn c_init(iss: u32) -> void {
    tcp_conn_init(&g_conn, iss);
}
export fn c_listen() -> void {
    tcp_listen(&g_conn);
}
export fn c_connect() -> u32 {
    return action_code(tcp_connect(&g_conn));
}
export fn c_segment(flags: u16, seq: u32) -> u32 {
    return action_code(tcp_on_segment(&g_conn, flags, seq));
}
export fn c_close() -> u32 {
    return action_code(tcp_close(&g_conn));
}
export fn c_state() -> u32 {
    return state_code(tcp_conn_state(&g_conn));
}
