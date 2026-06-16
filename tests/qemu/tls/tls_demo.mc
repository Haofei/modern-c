// Real TLS-over-TCP bridge: fine-grained TCP send/recv primitives that a BearSSL
// client (driven from the C runtime) uses as its record-layer transport.
//
// Unlike http_get_demo / dns_http_demo (which run the whole request/response in one
// monolithic MC drive loop), TLS needs the transport split into the two callbacks
// BearSSL calls repeatedly during the handshake and the application exchange:
//   low_write(buf,len)  -> tls_send : transmit `len` bytes as one TCP PSH|ACK segment
//   low_read(buf,max)   -> tls_recv : return the next inbound TCP data segment's payload
// Connection state (the TcpConn sequence accounting, the gateway MAC, our MAC, the
// peer endpoint, and the live NetDevice) is held in MC globals, established once by
// tls_net_up + (optionally) tls_resolve + tls_connect, then shared by every
// tls_send / tls_recv call. The frame builders/parsers are the same production
// kernel/net/tcp_tx + virtio_net used by the plaintext HTTP demos -- only the drive
// shape differs. No mocks: genuine TCP segments carrying real TLS records on the wire.

import "kernel/drivers/virtio/virtio_net.mc";
import "kernel/net/dns.mc";
import "kernel/net/ethernet.mc";
import "kernel/net/ipv4.mc";
import "kernel/net/udp.mc";
import "kernel/net/tcp_conn.mc";
import "kernel/net/tcp_tx.mc";
import "std/bytes.mc";
import "std/dma.mc";

const OUR_IP: u32 = 0x0A00_020F; // 10.0.2.15 (QEMU guest)
const GW_IP: u32 = 0x0A00_0202;  // 10.0.2.2  (QEMU slirp gateway -> host)

const OUR_PORT: u16 = 0xC000;    // 49152, ephemeral TCP source port
const DNS_SPORT: u16 = 0xC001;   // ephemeral UDP source port for the DNS query
const DNS_TXN: u16 = 0x4D43;     // "MC"
const TCP_WINDOW: u16 = 0x2000;  // advertised receive window

const DNSTX_NET_HDR: usize = 12;
const IP_PROTO_UDP_B: u8 = 17;

// ---- Connection state shared across the callbacks (set once, used many times). ----
global g_dev: NetDevice;
global g_src_mac: MacAddr;
global g_gw_mac: MacAddr;
global g_dst_ip: u32;
global g_dst_port: u16;
global g_conn: TcpConn;

// The runtime hands us a scratch RX region (one frame) to receive into.
global g_rxbuf: usize;
global g_rxmax: usize;

// RX hold buffer: one TCP segment's payload held across multiple low_read calls so the
// unconsumed tail of a multi-record segment is never dropped (see tls_recv).
const RXHOLD_CAP: usize = 2048;
global g_rxhold: [RXHOLD_CAP]u8;
global g_rxhold_len: usize; // bytes currently held
global g_rxhold_pos: usize; // next unread byte in the hold buffer
global g_rx_fin: bool;      // a FIN was observed after the held bytes are drained

// Hostname to resolve, pushed byte-by-byte by the runtime (MC has no string literals).
const HOST_CAP: usize = 64;
global g_host: [HOST_CAP]u8;
global g_host_len: usize;

export fn tls_host_reset() -> void {
    g_host_len = 0;
}
export fn tls_host_push(c: u8) -> void {
    if g_host_len < HOST_CAP {
        g_host[g_host_len] = c;
        g_host_len = g_host_len + 1;
    }
}

// The resolved IPv4 (host order), exposed for printing.
global g_resolved_ip: u32;
export fn tls_resolved_ip() -> u32 {
    return g_resolved_ip;
}

// -------------------------------------------------------------------- bring-up
// Initialise the NIC and ARP-resolve the gateway. Stash the live device + MACs in
// globals. Returns 1 on success, 0 on failure.
export fn tls_net_up(
    regs: MmioPtr<VirtioMmio>, rxq: *mut Virtq, txq: *mut Virtq,
    rxbuf: usize, rxmax: usize,
) -> u32 {
    g_rxbuf = rxbuf;
    g_rxmax = rxmax;
    g_resolved_ip = 0;

    g_dev = .{ .regs = regs, .rxq = rxq, .txq = txq };
    switch nic_init(&g_dev) {
        ok(up) => {}
        err(e) => { return 0; }
    }
    g_src_mac = .{ .bytes = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 } };

    g_gw_mac = .{ .bytes = .{ 0, 0, 0, 0, 0, 0 } };
    switch nic_arp_resolve(&g_dev, &g_src_mac, OUR_IP, GW_IP) {
        ok(m) => { g_gw_mac = m; }
        err(e) => { return 0; }
    }
    return 1;
}

// --------------------------------------------------------------------- DNS resolve
// Build + send a DNS A-query for g_host to dns_ip:53 over UDP.
fn send_dns_query(dns_ip: u32) -> bool {
    let eth_at: usize = DNSTX_NET_HDR;
    let ip_at: usize = eth_at + ETH_HDR_LEN; // 26
    let udp_at: usize = ip_at + 20;          // 46
    let dns_at: usize = udp_at + 8;          // 54

    let host_ptr: usize = (&g_host[0]) as usize;
    let max_dns: usize = 12 + g_host_len + 2 + 4;
    var cpu: CpuBuffer = alloc(dns_at + max_dns);

    var w: ByteWriter = byte_writer(cpu_addr(&cpu), cpu.len);
    let dns_len: usize = dns_build_query(&w, dns_at, DNS_TXN, host_ptr, g_host_len);

    eth_write_header(&cpu, eth_at, &g_gw_mac, &g_src_mac, ETHERTYPE_IPV4);
    ipv4_write_header(&cpu, ip_at, IP_PROTO_UDP_B, OUR_IP, dns_ip, 8 + dns_len);

    var w2: ByteWriter = byte_writer(cpu_addr(&cpu), cpu.len);
    udp_write(&w2, udp_at, OUR_IP, dns_ip, DNS_SPORT, 0x0035, dns_len);

    let total: usize = dns_at + dns_len;
    return nic_tx_frame(&g_dev, cpu, total);
}

fn recv_dns_response() -> bool {
    var tries: u32 = 0;
    while tries < 32 {
        let n: usize = nic_rx_into(&g_dev, g_rxbuf, g_rxmax);
        if n >= 42 {
            var r: ByteReader = byte_reader(phys(g_rxbuf), n);
            let ethertype: u16 = br_be16(&r, 12);
            if ethertype == 0x0800 {
                let ihl_byte: u8 = br_u8(&r, 14);
                let ihl: usize = ((ihl_byte & 0x0F) as usize) * 4;
                let proto: u8 = br_u8(&r, 14 + 9);
                if proto == 17 {
                    let udp_off: usize = 14 + ihl;
                    let sport: u16 = br_be16(&r, udp_off + 0);
                    let dport: u16 = br_be16(&r, udp_off + 2);
                    if sport == 0x0035 {
                        if dport == DNS_SPORT {
                            let dns_off: usize = udp_off + 8;
                            let dns_len: usize = n - dns_off;
                            switch dns_parse_response(g_rxbuf + dns_off, dns_len, DNS_TXN) {
                                ok(ip) => {
                                    g_resolved_ip = ip;
                                    return true;
                                }
                                err(e) => { return false; }
                            }
                        }
                    }
                }
            }
        }
        tries = tries + 1;
    }
    return false;
}

// Resolve g_host via dns_ip; returns the resolved host-order IPv4 (0 on failure).
export fn tls_resolve(dns_ip: u32) -> u32 {
    g_resolved_ip = 0;
    if !send_dns_query(dns_ip) {
        return 0;
    }
    if !recv_dns_response() {
        return 0;
    }
    return g_resolved_ip;
}

// ------------------------------------------------------------------ TCP connect
fn tx_segment(seq: u32, ack: u32, flags: u16, payload_src: usize, payload_len: usize) -> bool {
    let cpu: CpuBuffer = tcp_build_frame(
        &g_gw_mac, &g_src_mac, OUR_IP, g_dst_ip, OUR_PORT, g_dst_port,
        seq, ack, flags, TCP_WINDOW, payload_src, payload_len);
    let total: usize = cpu.len;
    return nic_tx_frame(&g_dev, cpu, total);
}

// Receive the next TCP segment addressed to our source port (bounded retries).
fn rx_tcp_segment() -> TcpRx {
    var none: TcpRx = .{
        .is_tcp = false, .src_port = 0, .dst_port = 0,
        .seq = 0, .ack = 0, .flags = 0, .window = 0,
        .payload_off = 0, .payload_len = 0,
    };
    var tries: u32 = 0;
    // TLS handshakes are several round-trips against a real server: keep a generous
    // spin so a slow ServerHello/Certificate burst is not missed.
    while tries < 20000 {
        let n: usize = nic_rx_into(&g_dev, g_rxbuf, g_rxmax);
        if n > 0 {
            let seg: TcpRx = tcp_parse_frame(g_rxbuf, n);
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

// Active-open a TCP connection to dst_ip:dst_port. Returns 1 (ESTABLISHED) or 0.
export fn tls_connect(dst_ip: u32, dst_port: u16) -> u32 {
    g_dst_ip = dst_ip;
    g_dst_port = dst_port;

    // Fresh connection: clear the RX hold buffer + EOF latch.
    g_rxhold_len = 0;
    g_rxhold_pos = 0;
    g_rx_fin = false;

    g_conn = .{ .state = .Closed, .snd_nxt = 0, .rcv_nxt = 0 };
    let act: TcpAction = tcp_connect(&g_conn);
    let _act: TcpAction = act;
    // SYN, ISN = 0.
    if !tx_segment(0, 0, TCP_SYN, 0, 0) {
        return 0;
    }
    let synack: TcpRx = rx_tcp_segment();
    if !synack.is_tcp {
        return 0;
    }
    let r1: TcpAction = tcp_on_segment(&g_conn, synack.flags, synack.seq);
    let _ignored1: TcpAction = r1;
    if !tcp_flag_set(synack.flags, TCP_SYN) {
        return 0;
    }
    if !tcp_flag_set(synack.flags, TCP_ACK) {
        return 0;
    }
    // ACK completing the handshake (seq = snd_nxt = 1, ack = rcv_nxt).
    if !tx_segment(g_conn.snd_nxt, g_conn.rcv_nxt, TCP_ACK, 0, 0) {
        return 0;
    }
    return 1; // ESTABLISHED
}

// -------------------------------------------------- BearSSL low_write callback
// Transmit [src, src+len) as a single TCP PSH|ACK data segment and advance snd_nxt.
// Returns the number of bytes sent (== len) on success, or -1 (0xFFFF_FFFF) on error.
// The runtime caps `len` at the MSS before calling, so one segment carries it all.
export fn tls_send(src: usize, len: usize) -> u32 {
    if len == 0 {
        return 0;
    }
    let psh_ack: u16 = TCP_PSH | TCP_ACK;
    if !tx_segment(g_conn.snd_nxt, g_conn.rcv_nxt, psh_ack, src, len) {
        return 0xFFFF_FFFF;
    }
    g_conn.snd_nxt = g_conn.snd_nxt + (len as u32);
    return len as u32;
}

// --------------------------------------------------- BearSSL low_read callback
// BearSSL calls low_read repeatedly with small `max` values: first 5 bytes for a TLS
// record header, then exactly the record body length. A single inbound TCP segment,
// however, routinely carries SEVERAL TLS records (the server writes header+body in one
// segment, and slirp coalesces). So we MUST NOT discard the unconsumed tail of a TCP
// segment -- doing so corrupts the record stream. Instead we hold the most recent
// in-order segment's payload in g_rxhold and drain it across successive low_read calls,
// fetching (and ACKing) a NEW segment only once the hold buffer is empty. rcv_nxt
// advances by the WHOLE segment on receipt (so the cumulative ACK is correct), not per
// low_read chunk.
//
// Pull the next in-order TCP data segment into g_rxhold (ACKing it). Returns:
//   1 = data buffered, 0 = clean EOF (FIN, no more data), 2 = error/timeout.
fn refill_rxhold() -> u32 {
    var spins: u32 = 0;
    while spins < 256 {
        let seg: TcpRx = rx_tcp_segment();
        if !seg.is_tcp {
            return 2; // timed out waiting for a segment
        }
        if seg.payload_len > 0 {
            if seg.seq == g_conn.rcv_nxt {
                // In-order: copy the WHOLE payload into the hold buffer (bounded by cap),
                // advance rcv_nxt by the whole payload, ACK cumulatively.
                var n: usize = seg.payload_len;
                if n > RXHOLD_CAP {
                    n = RXHOLD_CAP; // segment larger than our hold (shouldn't happen: MSS<cap)
                }
                var rr: ByteReader = byte_reader(phys(seg.payload_off), seg.payload_len);
                var i: usize = 0;
                while i < n {
                    g_rxhold[i] = br_u8(&rr, i);
                    i = i + 1;
                }
                g_rxhold_len = n;
                g_rxhold_pos = 0;
                g_conn.rcv_nxt = g_conn.rcv_nxt + (seg.payload_len as u32);
                if tcp_flag_set(seg.flags, TCP_FIN) {
                    g_conn.rcv_nxt = g_conn.rcv_nxt + 1; // FIN consumes one seq
                    g_rx_fin = true;
                }
                let _tx: bool = tx_segment(g_conn.snd_nxt, g_conn.rcv_nxt, TCP_ACK, 0, 0);
                return 1;
            }
            // Out-of-order / duplicate: re-ACK our cumulative point and keep waiting.
            let _dup: bool = tx_segment(g_conn.snd_nxt, g_conn.rcv_nxt, TCP_ACK, 0, 0);
        } else {
            // Pure control segment (a bare ACK, or a data-less FIN).
            if tcp_flag_set(seg.flags, TCP_FIN) {
                let fin_seq: u32 = seg.seq;
                if fin_seq == g_conn.rcv_nxt {
                    g_conn.rcv_nxt = g_conn.rcv_nxt + 1;
                    let _txf: bool = tx_segment(g_conn.snd_nxt, g_conn.rcv_nxt, TCP_ACK, 0, 0);
                }
                return 0; // clean EOF
            }
        }
        spins = spins + 1;
    }
    return 2;
}

// Return up to `max` bytes from the held segment, refilling from the wire as needed.
// Returns the byte count (>0), 0 on clean EOF, or -1 (0xFFFF_FFFF) on error/timeout.
export fn tls_recv(dst: usize, max: usize) -> u32 {
    if max == 0 {
        return 0;
    }
    // Drain whatever is still held before fetching a new segment.
    if g_rxhold_pos >= g_rxhold_len {
        if g_rx_fin {
            return 0; // all held data delivered and a FIN was seen -> clean EOF
        }
        let st: u32 = refill_rxhold();
        if st == 0 {
            return 0; // clean EOF
        }
        if st == 2 {
            return 0xFFFF_FFFF; // error/timeout
        }
        // st == 1: g_rxhold now holds fresh bytes.
    }
    var avail: usize = g_rxhold_len - g_rxhold_pos;
    var n: usize = avail;
    if n > max {
        n = max;
    }
    var w: ByteWriter = byte_writer(phys(dst), max);
    var i: usize = 0;
    while i < n {
        bw_u8(&w, i, g_rxhold[g_rxhold_pos + i]);
        i = i + 1;
    }
    g_rxhold_pos = g_rxhold_pos + n;
    return n as u32;
}
