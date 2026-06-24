// Real TLS-over-TCP bridge: fine-grained TCP send/recv primitives that a BearSSL
// client (driven from the C runtime) uses as its record-layer transport.
//
// Unlike http_get_demo / dns_http_demo (which run the whole request/response in one
// monolithic MC drive loop), TLS needs the transport split into the two callbacks
// BearSSL calls repeatedly during the handshake and the application exchange:
//   low_write(buf,len)  -> tls_send : transmit `len` bytes as one TCP PSH|ACK segment
//   low_read(buf,max)   -> tls_recv : return the next available application bytes
// Both now delegate to kernel/net/tcp_socket — the active-open, the sequence/window
// accounting, the ACKing, and (crucially) the multi-record segment-hold reassembly all
// live ONCE in the socket layer, not duplicated here. A single inbound TCP segment can
// carry several TLS records; tcp_socket_recv holds the segment and drains it across the
// successive small low_read calls, ACKing the whole segment exactly once. This file keeps
// only the TLS-specific bring-up: NIC up + ARP, optional DNS resolve, and the connection
// identity. No mocks: genuine TCP segments carrying real TLS records on the wire.

import "kernel/drivers/virtio/virtio_net.mc";
import "kernel/net/dns.mc";
import "kernel/net/ethernet.mc";
import "kernel/net/ipv4.mc";
import "kernel/net/udp.mc";
import "kernel/net/tcp_socket.mc";
import "std/bytes.mc";
import "std/alloc/dma.mc";

const OUR_IP: u32 = 0x0A00_020F; // 10.0.2.15 (QEMU guest)
const GW_IP: u32 = 0x0A00_0202;  // 10.0.2.2  (QEMU slirp gateway -> host)

const OUR_PORT: u16 = 0xC000;    // 49152, ephemeral TCP source port
const DNS_SPORT: u16 = 0xC001;   // ephemeral UDP source port for the DNS query
const DNS_TXN: u16 = 0x4D43;     // "MC"

const DNSTX_NET_HDR: usize = 12;
const IP_PROTO_UDP_B: u8 = 17;

// ---- Connection state shared across the callbacks (set once, used many times). ----
global g_dev: NetDevice;
global g_src_mac: MacAddr;
global g_gw_mac: MacAddr;
global g_sock: TcpSocket; // owns the TCP connection + window + reassembly + segment-hold

// The runtime hands us a scratch RX region (one frame) to receive into.
global g_rxbuf: usize;
global g_rxmax: usize;

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
// Active-open a TCP connection to dst_ip:dst_port via the socket layer. Returns 1
// (ESTABLISHED) or 0.
export fn tls_connect(dst_ip: u32, dst_port: u16) -> u32 {
    tcp_socket_init(&g_sock, &g_dev, g_rxbuf, g_rxmax);
    return tcp_socket_connect(&g_sock, &g_src_mac, &g_gw_mac, OUR_IP, dst_ip, OUR_PORT, dst_port);
}

// -------------------------------------------------- BearSSL low_write callback
// Transmit [src, src+len) as a single TCP PSH|ACK data segment and advance snd_nxt.
// Returns the number of bytes sent (== len) on success, or -1 (0xFFFF_FFFF) on error.
// The runtime caps `len` at the MSS before calling, so one segment carries it all.
export fn tls_send(src: usize, len: usize) -> u32 {
    return tcp_socket_send(&g_sock, src, len);
}

// --------------------------------------------------- BearSSL low_read callback
// Return up to `max` bytes of decrypted-transport application data. The socket layer holds
// the most recent in-order TCP segment and drains it across successive low_read calls (the
// multi-record-per-segment case), ACKing the whole segment once. Returns the byte count
// (>0), 0 on clean EOF, or -1 (0xFFFF_FFFF) on error/timeout.
export fn tls_recv(dst: usize, max: usize) -> u32 {
    return tcp_socket_recv(&g_sock, dst, max);
}
