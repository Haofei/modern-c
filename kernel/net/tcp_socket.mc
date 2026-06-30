// kernel/net/tcp_socket — a real TCP SOCKET layer: a connection abstraction that owns
// the control plane (kernel/net/tcp_conn state machine), the data-plane sequence/window
// bookkeeping (kernel/net/tcp_window), and an in-order sequence cursor (kernel/net/tcp_reasm
// is used only for its rcv_nxt; see below), and supplies the action→frame glue so callers
// never re-derive the active-open + send/recv loop.
//
// THE one place the inbound segment-hold lives: a single in-order TCP segment routinely carries
// SEVERAL application records (the peer writes header+body in one segment and the slirp gateway
// coalesces). tcp_socket_recv holds the most recent IN-ORDER segment's payload and drains it
// across successive calls. It delivers/ACKs ONLY the bytes it actually holds from the CURRENT
// frame (bounded by the hold buffer): rcv_nxt advances by exactly that many bytes, so an oversize
// segment is drained in chunks (the tail is left unacked for retransmission) and never silently
// dropped. Out-of-order segments are NOT buffered — only ordering metadata exists, not their
// payload bytes — they are re-ACKed at the cumulative point so the peer retransmits in order.
//
// The frame builders/parsers and the virtio-net device are the production
// kernel/net/tcp_tx + kernel/drivers/virtio/virtio_net used by the plaintext HTTP demos.

import "kernel/drivers/virtio/virtio_net.mc";
import "kernel/net/ethernet.mc";
import "kernel/net/tcp.mc";
import "kernel/net/tcp_conn.mc";
import "kernel/net/tcp_tx.mc";
import "kernel/net/tcp_window.mc";
import "kernel/net/tcp_reasm.mc";
import "std/bytes.mc";

const TCPSOCK_WINDOW: u16 = 0x2000;   // advertised receive window
const TCPSOCK_RXHOLD_CAP: usize = 2048; // one held TCP segment's payload (MSS < cap)

// A connection: the live device + endpoint identity, the three protocol layers it owns,
// the scratch RX region, and the receive segment-hold buffer.
struct TcpSocket {
    dev: *NetDevice,
    src_mac: MacAddr,
    gw_mac: MacAddr,
    src_ip: u32,
    dst_ip: u32,
    src_port: u16,
    dst_port: u16,

    conn: TcpConn,       // control plane (handshake / FIN)
    win: TcpWindow,      // data-plane send/recv sequence + window accounting
    reasm: Reassembler,  // receive reassembly (in-order delivery, dup/old drop)

    rxbuf: usize,        // scratch region the caller provides to receive one frame into
    rxmax: usize,

    rxhold: [TCPSOCK_RXHOLD_CAP]u8, // the held in-order segment payload
    rxhold_len: usize,   // bytes currently held
    rxhold_pos: usize,   // next unread byte in the hold buffer
    rx_fin: bool,        // a FIN was observed after the held bytes are drained
}

// Bind the socket to a device + RX scratch region (does not touch the wire). Call before
// tcp_socket_connect. The MAC/IP/port identity is filled in by connect.
export fn tcp_socket_init(s: *mut TcpSocket, dev: *NetDevice, rxbuf: usize, rxmax: usize) -> void {
    s.dev = dev;
    s.rxbuf = rxbuf;
    s.rxmax = rxmax;
    s.rxhold_len = 0;
    s.rxhold_pos = 0;
    s.rx_fin = false;
}

// ---- action→frame glue: consume a TcpAction / send a segment ----

// Transmit one TCP segment built from the socket's current sequence accounting.
fn sock_tx(s: *mut TcpSocket, seq: u32, ack: u32, flags: u16, payload_src: usize, payload_len: usize) -> bool {
    let cpu: CpuBuffer = tcp_build_frame(
        &s.gw_mac, &s.src_mac, s.src_ip, s.dst_ip, s.src_port, s.dst_port,
        seq, ack, flags, TCPSOCK_WINDOW, payload_src, payload_len);
    let total: usize = cpu.len;
    return nic_tx_frame(s.dev, cpu, total);
}

// Emit the control segment the state machine asked for (pure SYN/ACK/FIN). Data segments
// are sent directly by tcp_socket_send (they carry a payload the state machine does not
// model). Returns false on a TX failure for the segments that matter.
fn sock_emit(s: *mut TcpSocket, act: TcpAction) -> bool {
    let snd: u32 = tcp_win_snd_nxt(&s.win);
    let rcv: u32 = tcp_win_rcv_nxt(&s.win);
    switch act {
        .SendSyn => {
            // SYN carries seq = ISS (snd_una), ack ignored by peer.
            return sock_tx(s, tcp_win_snd_una(&s.win), 0, TCP_SYN, 0, 0);
        }
        .SendAck => {
            return sock_tx(s, snd, rcv, TCP_ACK, 0, 0);
        }
        .SendFin => {
            // FIN carries seq = snd_nxt-1 already consumed by the state machine; we resend
            // the current snd_nxt-relative point. snd_nxt has been bumped by tcp_close.
            return sock_tx(s, snd - 1, rcv, TCP_FIN | TCP_ACK, 0, 0);
        }
        .SendSynAck => {
            return sock_tx(s, tcp_win_snd_una(&s.win), rcv, TCP_SYN | TCP_ACK, 0, 0);
        }
        .None => { return true; }
    }
}

// Receive the next TCP segment addressed to our source port (bounded retries). Skips
// non-TCP frames (e.g. ARP) and TCP to other ports. is_tcp=false on timeout. `tries`
// bounds the spin (handshakes against a real server need a generous budget).
fn sock_rx(s: *mut TcpSocket, tries: u32) -> TcpRx {
    var none: TcpRx = .{
        .is_tcp = false, .src_port = 0, .dst_port = 0,
        .seq = 0, .ack = 0, .flags = 0, .window = 0,
        .payload_off = 0, .payload_len = 0,
    };
    var t: u32 = 0;
    while t < tries {
        let n: usize = nic_rx_into(s.dev, s.rxbuf, s.rxmax);
        if n > 0 {
            let seg: TcpRx = tcp_parse_frame(s.rxbuf, n);
            if seg.is_tcp {
                if seg.dst_port == s.src_port {
                    return seg;
                }
            }
        }
        t = t + 1;
    }
    return none;
}

// Drive an ARP-resolved active open all the way to ESTABLISHED. Returns 1 on success, 0 on
// failure (NIC/ARP failure or no SYN-ACK). The caller has already brought the NIC up.
export fn tcp_socket_connect(
    s: *mut TcpSocket,
    src_mac: *MacAddr, gw_mac: *MacAddr,
    src_ip: u32, dst_ip: u32,
    src_port: u16, dst_port: u16,
) -> u32 {
    s.src_mac = *src_mac;
    s.gw_mac = *gw_mac;
    s.src_ip = src_ip;
    s.dst_ip = dst_ip;
    s.src_port = src_port;
    s.dst_port = dst_port;

    // Fresh connection: clear the RX hold buffer + EOF latch.
    s.rxhold_len = 0;
    s.rxhold_pos = 0;
    s.rx_fin = false;

    // ISN = 0. tcp_connect → SynSent, snd_nxt = 1 (SYN consumes one).
    tcp_conn_init(&s.conn, 0);
    tcp_win_init(&s.win, 0, 0, TCPSOCK_WINDOW as u32);
    reasm_init(&s.reasm, 0);
    let act: TcpAction = tcp_connect(&s.conn);

    // Transmit the SYN (seq = ISS = 0).
    if !sock_emit(s, act) {
        return 0;
    }

    // Await the SYN-ACK to our source port (generous budget for a real server).
    let synack: TcpRx = sock_rx(s, 20000);
    if !synack.is_tcp {
        return 0;
    }
    if !tcp_flag_set(synack.flags, TCP_SYN) {
        return 0;
    }
    if !tcp_flag_set(synack.flags, TCP_ACK) {
        return 0;
    }
    // Feed the SYN-ACK to the state machine → Established, SendAck. It sets conn.rcv_nxt =
    // their_seq+1; mirror that into the window/reassembler.
    let r1: TcpAction = tcp_on_segment(&s.conn, synack.flags, synack.seq);
    let irs1: u32 = synack.seq + 1;
    tcp_win_init(&s.win, s.conn.snd_nxt, irs1, synack.window as u32);
    reasm_init(&s.reasm, irs1);

    // Transmit the ACK that completes the handshake.
    if !sock_emit(s, r1) {
        return 0;
    }
    return 1; // ESTABLISHED
}

// Send application data as one TCP PSH|ACK segment and advance snd_nxt. Returns the number
// of bytes sent (== len) on success, or 0xFFFF_FFFF on a TX error. (The caller caps `len`
// at the MSS, so one segment carries it all.)
export fn tcp_socket_send(s: *mut TcpSocket, src: usize, len: usize) -> u32 {
    if len == 0 {
        return 0;
    }
    let snd: u32 = tcp_win_snd_nxt(&s.win);
    let rcv: u32 = tcp_win_rcv_nxt(&s.win);
    let psh_ack: u16 = TCP_PSH | TCP_ACK;
    if !sock_tx(s, snd, rcv, psh_ack, src, len) {
        return 0xFFFF_FFFF;
    }
    tcp_win_on_send(&s.win, len as u32); // advance snd_nxt by the payload
    s.conn.snd_nxt = tcp_win_snd_nxt(&s.win);
    return len as u32;
}

// ---- the centralized in-order segment hold ----
//
// Pull the next in-order TCP data segment into the hold buffer, ACKing ONLY the bytes actually
// held from the current frame (an oversize segment is drained in chunks; out-of-order segments are
// re-ACKed, not buffered). Returns: 1 = data buffered, 0 = clean EOF (FIN, no more data), 2 = error/timeout.
fn sock_refill(s: *mut TcpSocket) -> u32 {
    var spins: u32 = 0;
    while spins < 256 {
        let seg: TcpRx = sock_rx(s, 20000);
        if !seg.is_tcp {
            return 2; // timed out waiting for a segment
        }
        let rcv: u32 = tcp_win_rcv_nxt(&s.win);
        if seg.payload_len > 0 {
            // The reassembler (tcp_reasm) stores only ORDERING metadata, never payload bytes — the
            // ONLY payload we have is the current frame's. So we deliver strictly the current
            // in-order segment, bounded by both its own length and the hold buffer, and never trust a
            // coalesced byte count: coalescing buffered out-of-order ranges would claim bytes whose
            // payload was never stored (over-reading this frame and ACKing data we do not hold).
            // `rcv` (= rcv_nxt) is the cumulative in-order cursor.
            if seg.seq == rcv {
                // In-order. Hold as much of THIS segment as fits; an oversize segment (anomalous —
                // MSS < cap) is DRAINED IN CHUNKS: ACK only the bytes held, leave the tail for the
                // peer to retransmit (it arrives next at the advanced rcv_nxt, in order).
                var hold: usize = seg.payload_len;
                let whole: bool = hold <= TCPSOCK_RXHOLD_CAP;
                if !whole {
                    hold = TCPSOCK_RXHOLD_CAP;
                }
                var rr: ByteReader = byte_reader(phys(seg.payload_off), seg.payload_len);
                var i: usize = 0;
                while i < hold {
                    s.rxhold[i] = br_u8(&rr, i);
                    i = i + 1;
                }
                s.rxhold_len = hold;
                s.rxhold_pos = 0;
                // Advance BOTH cursors by EXACTLY the bytes held (never more), so the ACK never
                // covers bytes we did not deliver and the trackers stay in lock-step.
                tcp_win_on_recv(&s.win, rcv, hold as u32);
                s.reasm.rcv_nxt = tcp_win_rcv_nxt(&s.win);
                if whole && tcp_flag_set(seg.flags, TCP_FIN) {
                    // FIN consumes one seq AFTER all the data — only when the whole segment landed
                    // (a truncated segment's tail, and its FIN, come on retransmission).
                    s.win.rcv_nxt = s.win.rcv_nxt + 1;
                    s.reasm.rcv_nxt = s.reasm.rcv_nxt + 1;
                    s.rx_fin = true;
                }
                sock_tx(s, tcp_win_snd_nxt(&s.win), tcp_win_rcv_nxt(&s.win), TCP_ACK, 0, 0);
                return 1;
            }
            // Out-of-order or duplicate (seq != rcv_nxt): we cannot hold its payload (only the
            // current frame's bytes exist, and they are not the next in-order bytes), so do NOT
            // buffer it — re-ACK our cumulative point so the peer retransmits from there, and wait.
            sock_tx(s, tcp_win_snd_nxt(&s.win), tcp_win_rcv_nxt(&s.win), TCP_ACK, 0, 0);
        } else {
            // Pure control segment (a bare ACK, or a data-less FIN).
            if tcp_flag_set(seg.flags, TCP_FIN) {
                if seg.seq == rcv {
                    s.win.rcv_nxt = s.win.rcv_nxt + 1;
                    s.reasm.rcv_nxt = s.reasm.rcv_nxt + 1;
                    sock_tx(s, tcp_win_snd_nxt(&s.win), tcp_win_rcv_nxt(&s.win), TCP_ACK, 0, 0);
                }
                return 0; // clean EOF
            }
        }
        spins = spins + 1;
    }
    return 2;
}

// Return up to `max` application bytes, refilling from the wire (ACKing only the bytes held from
// each in-order segment) as the hold buffer empties. Returns the byte count (>0), 0 on clean EOF, or 0xFFFF_FFFF
// on error/timeout. Draining the hold buffer across calls is what makes a multi-record TCP
// segment work: BearSSL asks for 5 bytes (record header) then the body length, repeatedly,
// and several records can sit in one segment.
export fn tcp_socket_recv(s: *mut TcpSocket, dst: usize, max: usize) -> u32 {
    if max == 0 {
        return 0;
    }
    // Drain whatever is still held before fetching a new segment.
    if s.rxhold_pos >= s.rxhold_len {
        if s.rx_fin {
            return 0; // all held data delivered and a FIN was seen → clean EOF
        }
        let st: u32 = sock_refill(s);
        if st == 0 {
            return 0; // clean EOF
        }
        if st == 2 {
            return 0xFFFF_FFFF; // error/timeout
        }
        // st == 1: the hold buffer now holds fresh bytes.
    }
    var avail: usize = s.rxhold_len - s.rxhold_pos;
    var n: usize = avail;
    if n > max {
        n = max;
    }
    var w: ByteWriter = byte_writer(phys(dst), max);
    var i: usize = 0;
    while i < n {
        bw_u8(&w, i, s.rxhold[s.rxhold_pos + i]);
        i = i + 1;
    }
    s.rxhold_pos = s.rxhold_pos + n;
    return n as u32;
}

// Current connection state (for callers that want to assert ESTABLISHED).
export fn tcp_socket_state(s: *mut TcpSocket) -> TcpState {
    return tcp_conn_state(&s.conn);
}
