// Real outbound HTTP GET over virtio-net under QEMU.
//
// Brings the NIC up, ARP-resolves the gateway, then drives a single TCP connection
// through a real 3-way handshake to a live HTTP server reachable via the slirp
// gateway: SYN → SYN-ACK → ACK, then PSH "GET / HTTP/1.0" → the server's real 200
// response → ACK. The TCP control plane is kernel/net/tcp_conn (pure state machine);
// the frames are built by kernel/net/tcp_tx and transmitted through the production
// virtio-net driver (nic_tx_frame); responses are parsed by tcp_parse_frame. No
// mocks — genuine packets, verified on the wire (pcap) and by the server access log.

import "kernel/drivers/virtio/virtio_net.mc";
import "kernel/net/tcp_conn.mc";
import "kernel/net/tcp_tx.mc";
import "std/bytes.mc";

const OUR_IP: u32 = 0x0A00_020F; // 10.0.2.15 (QEMU guest)
const GW_IP: u32 = 0x0A00_0202;  // 10.0.2.2  (QEMU slirp gateway → host)

const OUR_PORT: u16 = 0xC000;    // 49152, an ephemeral source port
const TCP_WINDOW: u16 = 0x2000;  // advertised receive window

// The accumulated HTTP response (filled by the drive loop, read back by the runtime).
const RESP_CAP: usize = 4096;
global g_resp: [RESP_CAP]u8;
global g_resp_len: usize;

// The GET request line. Host is the gateway address the guest connects to.
// "GET / HTTP/1.0\r\nHost: 10.0.2.2\r\n\r\n"
global g_req: [40]u8;
global g_req_len: usize;

fn req_set(i: usize, c: u8) -> void {
    g_req[i] = c;
}

// Build the request bytes into g_req (MC has no string literals to bytes helper here).
fn build_request() -> void {
    // "GET / HTTP/1.0\r\n"
    let s: usize = 0;
    req_set(s + 0, 0x47);  // G
    req_set(s + 1, 0x45);  // E
    req_set(s + 2, 0x54);  // T
    req_set(s + 3, 0x20);  // space
    req_set(s + 4, 0x2F);  // /
    req_set(s + 5, 0x20);  // space
    req_set(s + 6, 0x48);  // H
    req_set(s + 7, 0x54);  // T
    req_set(s + 8, 0x54);  // T
    req_set(s + 9, 0x50);  // P
    req_set(s + 10, 0x2F); // /
    req_set(s + 11, 0x31); // 1
    req_set(s + 12, 0x2E); // .
    req_set(s + 13, 0x30); // 0
    req_set(s + 14, 0x0D); // CR
    req_set(s + 15, 0x0A); // LF
    // "Host: 10.0.2.2\r\n"
    req_set(s + 16, 0x48); // H
    req_set(s + 17, 0x6F); // o
    req_set(s + 18, 0x73); // s
    req_set(s + 19, 0x74); // t
    req_set(s + 20, 0x3A); // :
    req_set(s + 21, 0x20); // space
    req_set(s + 22, 0x31); // 1
    req_set(s + 23, 0x30); // 0
    req_set(s + 24, 0x2E); // .
    req_set(s + 25, 0x30); // 0
    req_set(s + 26, 0x2E); // .
    req_set(s + 27, 0x32); // 2
    req_set(s + 28, 0x2E); // .
    req_set(s + 29, 0x32); // 2
    req_set(s + 30, 0x0D); // CR
    req_set(s + 31, 0x0A); // LF
    // "\r\n"
    req_set(s + 32, 0x0D); // CR
    req_set(s + 33, 0x0A); // LF
    g_req_len = 34;
}

// Append received payload bytes (read from raw region `src`) into g_resp. Reads
// through a bounds-checked ByteReader (no open-coded raw loads).
fn resp_append(src: usize, n: usize) -> void {
    if n == 0 {
        return;
    }
    var rr: ByteReader = byte_reader(phys(src), n);
    var i: usize = 0;
    while i < n {
        if g_resp_len < RESP_CAP {
            let b: u8 = br_u8(&rr, i);
            g_resp[g_resp_len] = b;
            g_resp_len = g_resp_len + 1;
        }
        i = i + 1;
    }
}

// Transmit one TCP segment built from the connection's current sequence accounting.
fn tx_segment(
    dev: *NetDevice, gw_mac: *MacAddr, src_mac: *MacAddr,
    dst_port: u16, seq: u32, ack: u32, flags: u16,
    payload_src: usize, payload_len: usize,
) -> bool {
    let cpu: CpuBuffer = tcp_build_frame(
        gw_mac, src_mac, OUR_IP, GW_IP, OUR_PORT, dst_port,
        seq, ack, flags, TCP_WINDOW, payload_src, payload_len);
    let total: usize = cpu.len;
    return nic_tx_frame(dev, cpu, total);
}

// Receive the next TCP segment addressed to our source port (bounded retries). Skips
// non-TCP frames (e.g. ARP) and TCP to other ports. Returns is_tcp=false on timeout.
fn rx_tcp_segment(dev: *NetDevice, buf: usize, max: usize) -> TcpRx {
    var none: TcpRx = .{
        .is_tcp = false, .src_port = 0, .dst_port = 0,
        .seq = 0, .ack = 0, .flags = 0, .window = 0,
        .payload_off = 0, .payload_len = 0,
    };
    var tries: u32 = 0;
    while tries < 16 {
        let n: usize = nic_rx_into(dev, buf, max);
        if n > 0 {
            let seg: TcpRx = tcp_parse_frame(buf, n);
            if seg.is_tcp {
                if seg.dst_port == OUR_PORT {
                    return seg;
                }
            }
        }
        tries = tries + 1;
    }
    return none;
}

// Drive the connection. Returns a status code:
//   0 = NIC/ARP failed; 1 = no SYN-ACK; 2 = handshake done but GET TX failed;
//   3 = handshake + GET done but no response; 4 = full success (response captured).
// `rxbuf`/`rxmax` is a scratch region the runtime provides to receive frames into.
export fn http_get_drive(
    regs: MmioPtr<VirtioMmio>, rxq: *mut Virtq, txq: *mut Virtq,
    dst_port: u16, rxbuf: usize, rxmax: usize,
) -> u32 {
    g_resp_len = 0;
    build_request();

    var dev: NetDevice = .{ .regs = regs, .rxq = rxq, .txq = txq };
    switch nic_init(&dev) {
        ok(up) => {}
        err(e) => { return 0; }
    }
    var src_mac: MacAddr = .{ .bytes = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 } };

    // Resolve the gateway MAC (ARP request → reply).
    var gw_mac: MacAddr = .{ .bytes = .{ 0, 0, 0, 0, 0, 0 } };
    switch nic_arp_resolve(&dev, &src_mac, OUR_IP, GW_IP) {
        ok(m) => { gw_mac = m; }
        err(e) => { return 0; }
    }

    // TCP active open: ISN = 0. After tcp_connect, snd_nxt = 1 (SYN consumes one).
    var conn: TcpConn = .{ .state = .Closed, .snd_nxt = 0, .rcv_nxt = 0 };
    let act: TcpAction = tcp_connect(&conn);
    let _act: TcpAction = act; // SendSyn
    // Transmit SYN with seq = ISN = 0.
    if !tx_segment(&dev, &gw_mac, &src_mac, dst_port, 0, 0, TCP_SYN, 0, 0) {
        return 0;
    }

    // Await the SYN-ACK to our source port.
    let synack: TcpRx = rx_tcp_segment(&dev, rxbuf, rxmax);
    if !synack.is_tcp {
        return 1;
    }
    // Feed flags + their seq to the state machine → Established, SendAck.
    let r1: TcpAction = tcp_on_segment(&conn, synack.flags, synack.seq);
    let _ignored1: TcpAction = r1;
    if !tcp_flag_set(synack.flags, TCP_SYN) {
        return 1;
    }
    if !tcp_flag_set(synack.flags, TCP_ACK) {
        return 1;
    }
    // rcv_nxt is now their_seq+1 (set by tcp_on_segment). snd_nxt is 1 (past our SYN).
    // Transmit the ACK that completes the handshake (seq=1, ack=rcv_nxt).
    if !tx_segment(&dev, &gw_mac, &src_mac, dst_port, conn.snd_nxt, conn.rcv_nxt, TCP_ACK, 0, 0) {
        return 1;
    }
    // ---- 3-way handshake complete: ESTABLISHED. ----

    // Transmit the GET as a PSH|ACK data segment.
    let req_addr: usize = (&g_req[0]) as usize;
    let psh_ack: u16 = TCP_PSH | TCP_ACK;
    if !tx_segment(&dev, &gw_mac, &src_mac, dst_port, conn.snd_nxt, conn.rcv_nxt, psh_ack, req_addr, g_req_len) {
        return 2;
    }
    conn.snd_nxt = conn.snd_nxt + (g_req_len as u32); // data consumes payload_len

    // Receive the response data segment(s); ACK each and accumulate the payload.
    var got_data: bool = false;
    var rounds: u32 = 0;
    while rounds < 64 {
        let seg: TcpRx = rx_tcp_segment(&dev, rxbuf, rxmax);
        if !seg.is_tcp {
            // No more segments arrived within the bounded wait.
            if got_data {
                return 4;
            }
            return 3;
        }
        if seg.payload_len > 0 {
            // In-order data: advance rcv_nxt and capture the bytes.
            if seg.seq == conn.rcv_nxt {
                resp_append(seg.payload_off, seg.payload_len);
                conn.rcv_nxt = conn.rcv_nxt + (seg.payload_len as u32);
                got_data = true;
            }
            // ACK whatever we have (cumulative).
            let _tx: bool = tx_segment(&dev, &gw_mac, &src_mac, dst_port, conn.snd_nxt, conn.rcv_nxt, TCP_ACK, 0, 0);
        }
        // A FIN also consumes one sequence number; ACK it so the server can close.
        if tcp_flag_set(seg.flags, TCP_FIN) {
            let fin_seq: u32 = seg.seq + (seg.payload_len as u32); // FIN sits after the segment's data
            if fin_seq == conn.rcv_nxt {
                conn.rcv_nxt = conn.rcv_nxt + 1;
                let _txf: bool = tx_segment(&dev, &gw_mac, &src_mac, dst_port, conn.snd_nxt, conn.rcv_nxt, TCP_ACK, 0, 0);
            }
            if got_data {
                return 4;
            }
            return 3;
        }
        rounds = rounds + 1;
    }
    if got_data {
        return 4;
    }
    return 3;
}

// Accessors for the runtime to read back the captured response.
export fn http_resp_len() -> usize {
    return g_resp_len;
}

export fn http_resp_byte(i: usize) -> u8 {
    if i < g_resp_len {
        return g_resp[i];
    }
    return 0;
}
