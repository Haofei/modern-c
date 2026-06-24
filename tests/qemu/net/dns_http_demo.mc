// Resolve-by-name then HTTP GET, over virtio-net under QEMU.
//
// Brings the NIC up, ARP-resolves the gateway, sends a REAL DNS A-query (built by
// kernel/net/dns) over UDP to a DNS server, receives the UDP response, parses the first
// A record to an IPv4 address, then reuses the http_get drive path (TCP 3-way
// handshake + "GET / HTTP/1.0" + response capture, built by kernel/net/tcp_tx) to fetch
// the resolved host on a given port. No mocks — genuine DNS + TCP packets on the wire.
//
// The hostname and the DNS-server / HTTP-port parameters are supplied by the C runtime,
// so one kernel serves both the deterministic local test (resolve "host.test" via a
// local DNS responder) and the best-effort real google.com fetch (via slirp 10.0.2.3).

import "kernel/drivers/virtio/virtio_net.mc";
import "kernel/net/dns.mc";
import "kernel/net/ethernet.mc";
import "kernel/net/ipv4.mc";
import "kernel/net/udp.mc";
import "kernel/net/tcp_conn.mc";
import "kernel/net/tcp_tx.mc";
import "std/bytes.mc";
import "std/alloc/dma.mc";

const OUR_IP: u32 = 0x0A00_020F; // 10.0.2.15 (QEMU guest)
const GW_IP: u32 = 0x0A00_0202;  // 10.0.2.2  (QEMU slirp gateway → host)

const OUR_PORT: u16 = 0xC000;    // 49152, ephemeral TCP source port
const DNS_SPORT: u16 = 0xC001;   // ephemeral UDP source port for the query
const DNS_TXN: u16 = 0x4D43;     // "MC" — the DNS transaction id
const TCP_WINDOW: u16 = 0x2000;

const DNSTX_NET_HDR: usize = 12; // virtio_net_hdr precedes the Ethernet frame
const IP_PROTO_UDP_B: u8 = 17;

// Hostname to resolve, set byte-by-byte by the runtime (MC has no string literals).
const HOST_CAP: usize = 64;
global g_host: [HOST_CAP]u8;
global g_host_len: usize;

export fn dns_host_reset() -> void {
    g_host_len = 0;
}
export fn dns_host_push(c: u8) -> void {
    if g_host_len < HOST_CAP {
        g_host[g_host_len] = c;
        g_host_len = g_host_len + 1;
    }
}

// The captured HTTP response (read back by the runtime).
const RESP_CAP: usize = 4096;
global g_resp: [RESP_CAP]u8;
global g_resp_len: usize;

// The resolved IPv4 (host order), exposed to the runtime for printing/verification.
global g_resolved_ip: u32;

export fn dns_resolved_ip() -> u32 {
    return g_resolved_ip;
}
export fn http_resp_len() -> usize {
    return g_resp_len;
}
export fn http_resp_byte(i: usize) -> u8 {
    if i < g_resp_len {
        return g_resp[i];
    }
    return 0;
}

// The GET request bytes. The default host header points at the gateway (matches the
// local deterministic test); the runtime may override the whole request byte-by-byte
// (e.g. the google.com fetch supplies "Host: google.com").
const REQ_CAP: usize = 128;
global g_req: [REQ_CAP]u8;
global g_req_len: usize;
global g_req_override: bool;

export fn dns_req_reset() -> void {
    g_req_len = 0;
    g_req_override = true;
}
export fn dns_req_push(c: u8) -> void {
    if g_req_len < REQ_CAP {
        g_req[g_req_len] = c;
        g_req_len = g_req_len + 1;
    }
}

fn build_request() -> void {
    if g_req_override {
        return; // the runtime already pushed a full request
    }
    // "GET / HTTP/1.0\r\nHost: 10.0.2.2\r\n\r\n"
    let b: [34]u8 = .{
        0x47, 0x45, 0x54, 0x20, 0x2F, 0x20, 0x48, 0x54, 0x54, 0x50, 0x2F, 0x31, 0x2E, 0x30, 0x0D, 0x0A,
        0x48, 0x6F, 0x73, 0x74, 0x3A, 0x20, 0x31, 0x30, 0x2E, 0x30, 0x2E, 0x32, 0x2E, 0x32, 0x0D, 0x0A,
        0x0D, 0x0A,
    };
    var i: usize = 0;
    while i < 34 {
        g_req[i] = b[i];
        i = i + 1;
    }
    g_req_len = 34;
}

fn resp_append(src: usize, n: usize) -> void {
    if n == 0 {
        return;
    }
    var rr: ByteReader = byte_reader(phys(src), n);
    var i: usize = 0;
    while i < n {
        if g_resp_len < RESP_CAP {
            let bb: u8 = br_u8(&rr, i);
            g_resp[g_resp_len] = bb;
            g_resp_len = g_resp_len + 1;
        }
        i = i + 1;
    }
}

// Build + transmit one DNS A-query for g_host to dns_ip:53 over UDP.
fn send_dns_query(dev: *NetDevice, gw_mac: *MacAddr, src_mac: *MacAddr, dns_ip: u32) -> bool {
    let eth_at: usize = DNSTX_NET_HDR;
    let ip_at: usize = eth_at + ETH_HDR_LEN; // 26
    let udp_at: usize = ip_at + 20;          // 46
    let dns_at: usize = udp_at + 8;          // 54

    // Build the DNS payload first (so we know its length), into a scratch writer over
    // the frame buffer. Worst case 12 + (len+2) + 4 bytes.
    let host_ptr: usize = (&g_host[0]) as usize;
    let max_dns: usize = 12 + g_host_len + 2 + 4;
    var cpu: CpuBuffer = alloc(dns_at + max_dns);

    var w: ByteWriter = byte_writer(cpu_addr(&cpu), cpu.len);
    let dns_len: usize = dns_build_query(&w, dns_at, DNS_TXN, host_ptr, g_host_len);

    // L2 / L3.
    eth_write_header(&cpu, eth_at, gw_mac, src_mac, ETHERTYPE_IPV4);
    ipv4_write_header(&cpu, ip_at, IP_PROTO_UDP_B, OUR_IP, dns_ip, 8 + dns_len);

    // L4 UDP (checksum over the DNS payload already in place).
    var w2: ByteWriter = byte_writer(cpu_addr(&cpu), cpu.len);
    udp_write(&w2, udp_at, OUR_IP, dns_ip, DNS_SPORT, 0x0035, dns_len); // dport 53

    let total: usize = dns_at + dns_len; // virtio hdr + eth + ip + udp + dns
    return nic_tx_frame(dev, cpu, total);
}

// Receive a UDP DNS response addressed to us and parse the first A record. Returns
// true and sets g_resolved_ip on success. `buf` is the runtime scratch RX region.
fn recv_dns_response(dev: *NetDevice, buf: usize, max: usize) -> bool {
    var tries: u32 = 0;
    while tries < 32 {
        let n: usize = nic_rx_into(dev, buf, max);
        if n >= 42 { // eth(14)+ip(20)+udp(8) minimum
            var r: ByteReader = byte_reader(phys(buf), n);
            let ethertype: u16 = br_be16(&r, 12);
            if ethertype == 0x0800 { // IPv4
                let ihl_byte: u8 = br_u8(&r, 14);
                let ihl: usize = ((ihl_byte & 0x0F) as usize) * 4;
                let proto: u8 = br_u8(&r, 14 + 9);
                if proto == 17 { // UDP
                    let udp_off: usize = 14 + ihl;
                    let sport: u16 = br_be16(&r, udp_off + 0);
                    let dport: u16 = br_be16(&r, udp_off + 2);
                    if sport == 0x0035 { // from port 53
                        if dport == DNS_SPORT {
                            let dns_off: usize = udp_off + 8;
                            let dns_len: usize = n - dns_off;
                            switch dns_parse_response(buf + dns_off, dns_len, DNS_TXN) {
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

fn tx_segment(
    dev: *NetDevice, gw_mac: *MacAddr, src_mac: *MacAddr, dst_ip: u32,
    dst_port: u16, seq: u32, ack: u32, flags: u16,
    payload_src: usize, payload_len: usize,
) -> bool {
    let cpu: CpuBuffer = tcp_build_frame(
        gw_mac, src_mac, OUR_IP, dst_ip, OUR_PORT, dst_port,
        seq, ack, flags, TCP_WINDOW, payload_src, payload_len);
    let total: usize = cpu.len;
    return nic_tx_frame(dev, cpu, total);
}

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

// Run the TCP handshake + GET against `dst_ip`:`dst_port`. Mirrors http_get_drive.
// Returns the same status codes (2=GET-TX-failed, 3=no response, 4=success).
fn http_drive_to(
    dev: *NetDevice, gw_mac: *MacAddr, src_mac: *MacAddr,
    dst_ip: u32, dst_port: u16, rxbuf: usize, rxmax: usize,
) -> u32 {
    var conn: TcpConn = .{ .state = .Closed, .snd_nxt = 0, .rcv_nxt = 0 };
    let act: TcpAction = tcp_connect(&conn);
    let _act: TcpAction = act;
    if !tx_segment(dev, gw_mac, src_mac, dst_ip, dst_port, 0, 0, TCP_SYN, 0, 0) {
        return 1;
    }
    let synack: TcpRx = rx_tcp_segment(dev, rxbuf, rxmax);
    if !synack.is_tcp {
        return 1;
    }
    let r1: TcpAction = tcp_on_segment(&conn, synack.flags, synack.seq);
    let _ignored1: TcpAction = r1;
    if !tcp_flag_set(synack.flags, TCP_SYN) {
        return 1;
    }
    if !tcp_flag_set(synack.flags, TCP_ACK) {
        return 1;
    }
    if !tx_segment(dev, gw_mac, src_mac, dst_ip, dst_port, conn.snd_nxt, conn.rcv_nxt, TCP_ACK, 0, 0) {
        return 1;
    }

    let req_addr: usize = (&g_req[0]) as usize;
    let psh_ack: u16 = TCP_PSH | TCP_ACK;
    if !tx_segment(dev, gw_mac, src_mac, dst_ip, dst_port, conn.snd_nxt, conn.rcv_nxt, psh_ack, req_addr, g_req_len) {
        return 2;
    }
    conn.snd_nxt = conn.snd_nxt + (g_req_len as u32);

    var got_data: bool = false;
    var rounds: u32 = 0;
    while rounds < 64 {
        let seg: TcpRx = rx_tcp_segment(dev, rxbuf, rxmax);
        if !seg.is_tcp {
            if got_data {
                return 4;
            }
            return 3;
        }
        if seg.payload_len > 0 {
            if seg.seq == conn.rcv_nxt {
                resp_append(seg.payload_off, seg.payload_len);
                conn.rcv_nxt = conn.rcv_nxt + (seg.payload_len as u32);
                got_data = true;
            }
            let _tx: bool = tx_segment(dev, gw_mac, src_mac, dst_ip, dst_port, conn.snd_nxt, conn.rcv_nxt, TCP_ACK, 0, 0);
        }
        if tcp_flag_set(seg.flags, TCP_FIN) {
            let fin_seq: u32 = seg.seq + (seg.payload_len as u32);
            if fin_seq == conn.rcv_nxt {
                conn.rcv_nxt = conn.rcv_nxt + 1;
                let _txf: bool = tx_segment(dev, gw_mac, src_mac, dst_ip, dst_port, conn.snd_nxt, conn.rcv_nxt, TCP_ACK, 0, 0);
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

// Resolve g_host via `dns_ip`, then HTTP GET the resolved address on `http_port`.
// Status: 0 = NIC/ARP failed; 5 = DNS query TX failed; 6 = no/invalid DNS response;
// otherwise the http_drive_to status (1 no-syn-ack, 2 GET-TX, 3 no-resp, 4 success).
export fn dns_http_drive(
    regs: MmioPtr<VirtioMmio>, rxq: *mut Virtq, txq: *mut Virtq,
    dns_ip: u32, http_port: u16, rxbuf: usize, rxmax: usize,
) -> u32 {
    g_resp_len = 0;
    g_resolved_ip = 0;
    build_request();

    var dev: NetDevice = .{ .regs = regs, .rxq = rxq, .txq = txq };
    switch nic_init(&dev) {
        ok(up) => {}
        err(e) => { return 0; }
    }
    var src_mac: MacAddr = .{ .bytes = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 } };

    var gw_mac: MacAddr = .{ .bytes = .{ 0, 0, 0, 0, 0, 0 } };
    switch nic_arp_resolve(&dev, &src_mac, OUR_IP, GW_IP) {
        ok(m) => { gw_mac = m; }
        err(e) => { return 0; }
    }

    if !send_dns_query(&dev, &gw_mac, &src_mac, dns_ip) {
        return 5;
    }
    if !recv_dns_response(&dev, rxbuf, rxmax) {
        return 6;
    }

    return http_drive_to(&dev, &gw_mac, &src_mac, g_resolved_ip, http_port, rxbuf, rxmax);
}
