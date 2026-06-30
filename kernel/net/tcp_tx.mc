// kernel/net/tcp_tx — build a complete TCP/IPv4/Ethernet TX frame for the virtio-net
// driver, and parse a received TCP/IPv4 frame into plain fields.
//
// This is the glue between the pure TCP state machine (kernel/net/tcp_conn) and the
// frame builders (ethernet/ipv4/tcp): it lays out one CpuBuffer with the virtio-net
// header, Ethernet header (to the gateway MAC), IPv4 header (proto 6), TCP header
// (checksummed over the pseudo-header) and the optional payload, ready to hand to
// `nic_tx_frame`. The receive side classifies an inbound frame as TCP and extracts
// the sequence/ack/flags/window and the payload extent so a client loop can advance
// its sequence accounting and read the response body.

import "std/alloc/dma.mc";
import "std/bytes.mc";
import "kernel/net/ethernet.mc";
import "kernel/net/ipv4.mc";
import "kernel/net/tcp.mc";
import "kernel/net/inet_checksum.mc";

const TCPTX_NET_HDR: usize = 12;        // virtio_net_hdr precedes the Ethernet frame
const TCPTX_IP_PROTO_TCP: u8 = 6;
const TCPTX_ETH_MIN: usize = 60;        // pad short frames up to the Ethernet minimum

// Build a TCP segment frame into a freshly allocated CpuBuffer and return it along
// with the framed length (virtio hdr + Ethernet payload). The payload bytes (if any)
// are supplied through `payload_src`/`payload_len`: each byte is read from the raw
// region [payload_src, payload_src+payload_len) and copied after the TCP header
// *before* the checksum is computed (tcp_write sums over the payload). Pass
// payload_len = 0 for a pure control segment (SYN/ACK/FIN).
export fn tcp_build_frame(
    dst_mac: *MacAddr, src_mac: *MacAddr,
    src_ip: u32, dst_ip: u32,
    src_port: u16, dst_port: u16,
    seq: u32, ack: u32, flags: u16, window: u16,
    payload_src: usize, payload_len: usize,
) -> CpuBuffer {
    let eth_at: usize = TCPTX_NET_HDR;          // 12
    let ip_at: usize = eth_at + ETH_HDR_LEN;    // 26
    let tcp_at: usize = ip_at + 20;             // 46
    let payload_at: usize = tcp_at + 20;        // 66

    var frame_len: usize = ETH_HDR_LEN + 20 + 20 + payload_len; // eth+ip+tcp+payload
    if frame_len < TCPTX_ETH_MIN {
        frame_len = TCPTX_ETH_MIN; // zero-padded tail (allocator zeroes the buffer)
    }
    var cpu: CpuBuffer = alloc(TCPTX_NET_HDR + frame_len);

    // L2: Ethernet to the gateway MAC.
    eth_write_header(&cpu, eth_at, dst_mac, src_mac, ETHERTYPE_IPV4);

    // L3: IPv4, protocol TCP, payload = the TCP segment (header + data).
    ipv4_write_header(&cpu, ip_at, TCPTX_IP_PROTO_TCP, src_ip, dst_ip, 20 + payload_len);

    // Copy the application payload in *before* tcp_write (it checksums over it). The
    // source is read through a bounds-checked ByteReader (no open-coded raw loads).
    if payload_len > 0 {
        var pr: ByteReader = byte_reader(phys(payload_src), payload_len);
        var i: usize = 0;
        while i < payload_len {
            let b: u8 = br_u8(&pr, i);
            write_u8(&cpu, payload_at + i, b);
            i = i + 1;
        }
    }

    // L4: TCP header + pseudo-header checksum over the same buffer memory.
    var w: ByteWriter = byte_writer(cpu_addr(&cpu), cpu.len);
    tcp_write(&w, tcp_at, src_ip, dst_ip, src_port, dst_port, seq, ack, flags, window, payload_len);

    return cpu;
}

// A received TCP/IPv4 segment parsed into plain copyable fields. `is_tcp` is false
// for any frame that is not IPv4-proto-6 (or is too short / fails the IP checksum);
// the rest of the fields are then meaningless.
struct TcpRx {
    is_tcp: bool,
    src_port: u16,
    dst_port: u16,
    seq: u32,
    ack: u32,
    flags: u16,
    window: u16,
    payload_off: usize, // absolute address of the first payload byte (base + header offset)
    payload_len: usize, // number of payload bytes (segment total length - headers)
}

// Parse an Ethernet frame of `len` bytes starting at offset 0 of the raw region
// `base` (as copied out by `nic_rx_into`, i.e. the virtio header already stripped).
// Returns is_tcp=false for anything that is not a well-formed IPv4 TCP segment.
export fn tcp_parse_frame(base: usize, len: usize) -> TcpRx {
    var out: TcpRx = .{
        .is_tcp = false, .src_port = 0, .dst_port = 0,
        .seq = 0, .ack = 0, .flags = 0, .window = 0,
        .payload_off = 0, .payload_len = 0,
    };
    let min_frame: usize = 54; // 14 eth + 20 ip + 20 tcp (minimum)
    if len < min_frame {
        return out; // too short for eth + ip + tcp
    }
    var r: ByteReader = byte_reader(phys(base), len);

    // Every field is read through the total checked reader (br_try_*): a frame that
    // claims more than it delivers (a hostile IHL / data-offset / total-length) makes
    // a read return OutOfBounds, and we reject cleanly (is_tcp=false) instead of
    // trapping. The explicit length guards stay as the semantic checks; safety no
    // longer depends on them being exhaustive — over-read is impossible here.
    var ethertype: u16 = 0;
    switch br_try_be16(&r, 12) { ok(v) => { ethertype = v; } err(e) => { return out; } }
    if ethertype != ETHERTYPE_IPV4 {
        return out;
    }
    let ip_at: usize = 14;
    // IHL (low nibble of byte 0) words → header byte length.
    var vihl: u8 = 0;
    switch br_try_u8(&r, ip_at) { ok(v) => { vihl = v; } err(e) => { return out; } }
    let ihl_words: usize = (vihl & 0x0F) as usize;
    let ip_hdr_len: usize = ihl_words * 4;
    if ip_hdr_len < 20 {
        return out;
    }
    var proto: u8 = 0;
    switch br_try_u8(&r, ip_at + 9) { ok(v) => { proto = v; } err(e) => { return out; } }
    if proto != TCPTX_IP_PROTO_TCP {
        return out;
    }
    var ip_total_raw: u16 = 0;
    switch br_try_be16(&r, ip_at + 2) { ok(v) => { ip_total_raw = v; } err(e) => { return out; } }
    let ip_total: usize = ip_total_raw as usize; // IP total length (header+payload)
    let ip_min: usize = ip_hdr_len + 20; // IP header + a full TCP header
    if ip_total < ip_min {
        return out;
    }
    // P2: ip_total is an UNTRUSTED length from the wire. Validate that the bytes IP
    // claims (the IP datagram starting at ip_at) actually fit in the frame BEFORE any
    // of them are used as a bound — a hostile total-length that claims more than was
    // delivered is rejected cleanly here (named check), so it can never push the TCP
    // header / payload extents past the buffer.
    switch br_validate_len(&r, ip_at, ip_total) {
        ok(u) => {}
        err(e) => { return out; } // IP claims more than the frame delivered
    }
    let tcp_at: usize = ip_at + ip_hdr_len;
    var off_flags: u16 = 0;
    switch br_try_be16(&r, tcp_at + 12) { ok(v) => { off_flags = v; } err(e) => { return out; } }
    let data_off_words: usize = ((off_flags >> 12) & 0x0F) as usize;
    let tcp_hdr_len: usize = data_off_words * 4;
    if tcp_hdr_len < 20 {
        return out;
    }
    let seg_total: usize = ip_total - ip_hdr_len; // TCP header + payload
    if seg_total < tcp_hdr_len {
        return out;
    }
    // Checksum validation: reject a corrupt frame before its fields reach socket/window state.
    // All summed bytes are already proven in-bounds (br_validate_len above + seg_total<=ip_total),
    // so inet_sum's reads cannot run off the frame. The IPv4 header checksum covers the IP header;
    // a valid header (checksum field included) folds to all-ones. The TCP checksum covers the IPv4
    // pseudo-header + the whole TCP segment.
    if !checksum_valid(inet_sum(&r, ip_at, ip_hdr_len, 0)) {
        return out; // bad IPv4 header checksum
    }
    var src_ip_be: u32 = 0;
    var dst_ip_be: u32 = 0;
    switch br_try_be32(&r, ip_at + 12) { ok(v) => { src_ip_be = v; } err(e) => { return out; } }
    switch br_try_be32(&r, ip_at + 16) { ok(v) => { dst_ip_be = v; } err(e) => { return out; } }
    if !tcp_checksum_valid(&r, tcp_at, src_ip_be, dst_ip_be, seg_total as u16) {
        return out; // bad TCP checksum (pseudo-header + segment)
    }
    var src_port: u16 = 0;
    var dst_port: u16 = 0;
    var seq: u32 = 0;
    var ack: u32 = 0;
    var window: u16 = 0;
    switch br_try_be16(&r, tcp_at + 0) { ok(v) => { src_port = v; } err(e) => { return out; } }
    switch br_try_be16(&r, tcp_at + 2) { ok(v) => { dst_port = v; } err(e) => { return out; } }
    switch br_try_be32(&r, tcp_at + 4) { ok(v) => { seq = v; } err(e) => { return out; } }
    switch br_try_be32(&r, tcp_at + 8) { ok(v) => { ack = v; } err(e) => { return out; } }
    switch br_try_be16(&r, tcp_at + 14) { ok(v) => { window = v; } err(e) => { return out; } }
    out.is_tcp = true;
    out.src_port = src_port;
    out.dst_port = dst_port;
    out.seq = seq;
    out.ack = ack;
    out.flags = off_flags & 0x01FF;
    out.window = window;
    out.payload_off = base + tcp_at + tcp_hdr_len; // absolute address of the payload
    out.payload_len = seg_total - tcp_hdr_len;
    return out;
}
