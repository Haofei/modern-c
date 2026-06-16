// kernel/net/udp — build and parse UDP datagrams (RFC 768) over IPv4.
//
// Operates on bounds-checked byte readers/writers (std/bytes), so header fields are
// never written or read off the end of the packet buffer. The internet checksum is
// computed over the IPv4 pseudo-header plus the UDP segment. IP addresses are passed
// as raw host-order u32s (the caller holds the typed Ipv4Addr).

import "std/bytes.mc";
import "kernel/net/inet_checksum.mc";

const UDP_HEADER_LEN: usize = 8;
const IP_PROTO_UDP: u32 = 17;

struct UdpHeader {
    src_port: u16,
    dst_port: u16,
    length: u16, // header + payload, in bytes
}

// Write the UDP header at `off` (the `payload_len`-byte payload must already be at
// off + 8). Computes and stores the checksum over the pseudo-header + segment.
export fn udp_write(w: *ByteWriter, off: usize, src_ip: u32, dst_ip: u32, src_port: u16, dst_port: u16, payload_len: usize) -> void {
    let total: u16 = (UDP_HEADER_LEN + payload_len) as u16;
    bw_be16(w, off, src_port);
    bw_be16(w, off + 2, dst_port);
    bw_be16(w, off + 4, total);
    bw_be16(w, off + 6, 0); // checksum field zero while summing

    var r: ByteReader = byte_reader(w.base, w.len);
    var sum: u32 = inet_pseudo_sum(src_ip, dst_ip, IP_PROTO_UDP, total);
    sum = inet_sum(&r, off, UDP_HEADER_LEN + payload_len, sum);
    bw_be16(w, off + 6, checksum_finalize_udp(sum));
}

// Parse the UDP header at `off`.
export fn udp_parse(r: *ByteReader, off: usize) -> UdpHeader {
    return .{
        .src_port = br_be16(r, off),
        .dst_port = br_be16(r, off + 2),
        .length = br_be16(r, off + 4),
    };
}

// Validate the UDP checksum: summing the pseudo-header + the whole segment
// (checksum field included) yields all-ones when correct.
export fn udp_checksum_valid(r: *ByteReader, off: usize, src_ip: u32, dst_ip: u32) -> bool {
    let total: u16 = br_be16(r, off + 4);
    var sum: u32 = inet_pseudo_sum(src_ip, dst_ip, IP_PROTO_UDP, total);
    sum = inet_sum(r, off, total as usize, sum);
    return checksum_valid(sum);
}
