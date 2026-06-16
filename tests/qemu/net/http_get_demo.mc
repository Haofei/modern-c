// Real outbound HTTP GET over virtio-net under QEMU.
//
// Brings the NIC up, ARP-resolves the gateway, then drives a single TCP connection
// through a real 3-way handshake to a live HTTP server reachable via the slirp
// gateway: SYN → SYN-ACK → ACK, then PSH "GET / HTTP/1.0" → the server's real 200
// response → ACK. The active-open + send/recv/ACK/reassembly loop is NOT hand-rolled
// here: it lives once in kernel/net/tcp_socket (which owns the tcp_conn state machine,
// the tcp_window sequence accounting and the tcp_reasm receive reassembly, and does the
// action→frame glue through kernel/net/tcp_tx + the production virtio-net driver). No
// mocks — genuine packets, verified on the wire (pcap) and by the server access log.

import "kernel/drivers/virtio/virtio_net.mc";
import "kernel/net/tcp_socket.mc";
import "std/bytes.mc";

const OUR_IP: u32 = 0x0A00_020F; // 10.0.2.15 (QEMU guest)
const GW_IP: u32 = 0x0A00_0202;  // 10.0.2.2  (QEMU slirp gateway → host)

const OUR_PORT: u16 = 0xC000;    // 49152, an ephemeral source port

// The accumulated HTTP response (filled by the drive loop, read back by the runtime).
const RESP_CAP: usize = 4096;
global g_resp: [RESP_CAP]u8;
global g_resp_len: usize;

// The GET request line. Host is the gateway address the guest connects to.
// "GET / HTTP/1.0\r\nHost: 10.0.2.2\r\n\r\n"
global g_req: [40]u8;
global g_req_len: usize;

// The socket: owns the connection (state machine + window + reassembly + segment-hold).
global g_sock: TcpSocket;

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

// Append received payload bytes (read from raw region `src`) into g_resp.
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

    // TCP active open via the socket layer (SYN → SYN-ACK → ACK → ESTABLISHED).
    tcp_socket_init(&g_sock, &dev, rxbuf, rxmax);
    if tcp_socket_connect(&g_sock, &src_mac, &gw_mac, OUR_IP, GW_IP, OUR_PORT, dst_port) == 0 {
        return 1;
    }

    // Transmit the GET as a PSH|ACK data segment.
    let req_addr: usize = (&g_req[0]) as usize;
    if tcp_socket_send(&g_sock, req_addr, g_req_len) == 0xFFFF_FFFF {
        return 2;
    }

    // Read the response: the socket layer drains multi-record segments and ACKs them.
    var got_data: bool = false;
    while true {
        var chunk: [512]u8 = uninit;
        let chunk_addr: usize = (&chunk[0]) as usize;
        let n: u32 = tcp_socket_recv(&g_sock, chunk_addr, 512);
        if n == 0 {
            break; // clean EOF (FIN)
        }
        if n == 0xFFFF_FFFF {
            break; // timeout / no more segments
        }
        resp_append(chunk_addr, n as usize);
        got_data = true;
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
