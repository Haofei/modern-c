// kernel/net/tcp_conn — a TCP connection state machine (RFC 793).
//
// Tracks the connection state and the send/receive sequence numbers, and computes
// the next state + the control segment to emit for each event (open, received
// segment, application close). This is the protocol's control plane; the data plane
// (windowing, retransmission, reassembly) layers on top. Unhandled segments in a
// state are ignored (return `None`) rather than mishandled.

import "kernel/net/tcp.mc";

enum TcpState {
    Closed,
    Listen,
    SynSent,
    SynReceived,
    Established,
    FinWait1,
    FinWait2,
    CloseWait,
    LastAck,
    TimeWait,
}

// The control segment the state machine wants emitted in response to an event.
enum TcpAction {
    None,
    SendSyn,
    SendSynAck,
    SendAck,
    SendFin,
}

struct TcpConn {
    state: TcpState,
    snd_nxt: u32, // next sequence number we will send
    rcv_nxt: u32, // next sequence number we expect to receive
}

export fn tcp_conn_init(c: *mut TcpConn, iss: u32) -> void {
    c.state = .Closed;
    c.snd_nxt = iss;
    c.rcv_nxt = 0;
}

// Passive open: wait for an incoming SYN.
export fn tcp_listen(c: *mut TcpConn) -> void {
    c.state = .Listen;
}

// Active open: send a SYN.
export fn tcp_connect(c: *mut TcpConn) -> TcpAction {
    c.state = .SynSent;
    c.snd_nxt = c.snd_nxt + 1; // SYN consumes one sequence number
    return .SendSyn;
}

// Process a received segment (its control flags + sequence number) and return the
// control segment to emit.
export fn tcp_on_segment(c: *mut TcpConn, flags: u16, seg_seq: u32) -> TcpAction {
    let st: TcpState = c.state;
    switch st {
        .Listen => {
            if tcp_flag_set(flags, TCP_SYN) {
                c.rcv_nxt = seg_seq + 1;
                c.snd_nxt = c.snd_nxt + 1; // our SYN
                c.state = .SynReceived;
                return .SendSynAck;
            }
            return .None;
        }
        .SynSent => {
            if tcp_flag_set(flags, TCP_SYN) {
                if tcp_flag_set(flags, TCP_ACK) {
                    c.rcv_nxt = seg_seq + 1;
                    c.state = .Established;
                    return .SendAck;
                }
            }
            return .None;
        }
        .SynReceived => {
            if tcp_flag_set(flags, TCP_ACK) {
                c.state = .Established;
            }
            return .None;
        }
        .Established => {
            if tcp_flag_set(flags, TCP_FIN) {
                c.rcv_nxt = seg_seq + 1;
                c.state = .CloseWait;
                return .SendAck;
            }
            return .None;
        }
        .FinWait1 => {
            if tcp_flag_set(flags, TCP_ACK) {
                c.state = .FinWait2;
            }
            return .None;
        }
        .FinWait2 => {
            if tcp_flag_set(flags, TCP_FIN) {
                c.rcv_nxt = seg_seq + 1;
                c.state = .TimeWait;
                return .SendAck;
            }
            return .None;
        }
        .LastAck => {
            if tcp_flag_set(flags, TCP_ACK) {
                c.state = .Closed;
            }
            return .None;
        }
        .Closed => {
            return .None;
        }
        .CloseWait => {
            return .None;
        }
        .TimeWait => {
            return .None;
        }
    }
}

// Application close: send a FIN (from ESTABLISHED or CLOSE_WAIT).
export fn tcp_close(c: *mut TcpConn) -> TcpAction {
    let st: TcpState = c.state;
    switch st {
        .Established => {
            c.snd_nxt = c.snd_nxt + 1;
            c.state = .FinWait1;
            return .SendFin;
        }
        .CloseWait => {
            c.snd_nxt = c.snd_nxt + 1;
            c.state = .LastAck;
            return .SendFin;
        }
        .Closed => {
            return .None;
        }
        .Listen => {
            c.state = .Closed;
            return .None;
        }
        .SynSent => {
            c.state = .Closed;
            return .None;
        }
        .SynReceived => {
            return .None;
        }
        .FinWait1 => {
            return .None;
        }
        .FinWait2 => {
            return .None;
        }
        .LastAck => {
            return .None;
        }
        .TimeWait => {
            return .None;
        }
    }
}

export fn tcp_conn_state(c: *mut TcpConn) -> TcpState {
    return c.state;
}
