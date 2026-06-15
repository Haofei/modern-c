// kernel/net/tcp — build and parse TCP segments (RFC 793) over IPv4.
//
// Header build/parse over bounds-checked byte readers/writers, with the IPv4
// pseudo-header internet checksum (shared with UDP). Options are not emitted (data
// offset = 5 words); the control flags are exposed for the connection state machine
// to come. IP addresses are raw host-order u32s.

import "std/bytes.mc";
import "kernel/net/inet_checksum.mc";

const TCP_HEADER_LEN: usize = 20;
const IP_PROTO_TCP: u32 = 6;
const TCP_DATA_OFFSET_5: u16 = 0x5000; // data offset = 5 32-bit words, in the high nibble of byte 12

const TCP_FIN: u16 = 0x01;
const TCP_SYN: u16 = 0x02;
const TCP_RST: u16 = 0x04;
const TCP_PSH: u16 = 0x08;
const TCP_ACK: u16 = 0x10;

struct TcpHeader {
    src_port: u16,
    dst_port: u16,
    seq: u32,
    ack: u32,
    flags: u16, // the 9 control bits
    window: u16,
}

// Write a TCP header at `off` (no options, data offset = 5 words); the payload must
// already be at off + 20. Computes the checksum over the pseudo-header + segment.
export fn tcp_write(w: *ByteWriter, off: usize, src_ip: u32, dst_ip: u32, src_port: u16, dst_port: u16, seq: u32, ack: u32, flags: u16, window: u16, payload_len: usize) -> void {
    bw_be16(w, off, src_port);
    bw_be16(w, off + 2, dst_port);
    bw_be32(w, off + 4, seq);
    bw_be32(w, off + 8, ack);
    let offset_flags: u16 = TCP_DATA_OFFSET_5 | (flags & 0x01FF);
    bw_be16(w, off + 12, offset_flags);
    bw_be16(w, off + 14, window);
    bw_be16(w, off + 16, 0); // checksum (zero while summing)
    bw_be16(w, off + 18, 0); // urgent pointer

    let seg_len: u16 = (TCP_HEADER_LEN + payload_len) as u16;
    var r: ByteReader = byte_reader(w.base, w.len);
    var sum: u32 = inet_pseudo_sum(src_ip, dst_ip, IP_PROTO_TCP, seg_len);
    sum = inet_sum(&r, off, TCP_HEADER_LEN + payload_len, sum);
    bw_be16(w, off + 16, inet_fold(sum) ^ 0xFFFF);
}

export fn tcp_parse(r: *ByteReader, off: usize) -> TcpHeader {
    let offset_flags: u16 = br_be16(r, off + 12);
    return .{
        .src_port = br_be16(r, off),
        .dst_port = br_be16(r, off + 2),
        .seq = br_be32(r, off + 4),
        .ack = br_be32(r, off + 8),
        .flags = offset_flags & 0x01FF,
        .window = br_be16(r, off + 14),
    };
}

// Validate the TCP checksum over a `seg_len`-byte segment (length comes from IP).
export fn tcp_checksum_valid(r: *ByteReader, off: usize, src_ip: u32, dst_ip: u32, seg_len: u16) -> bool {
    var sum: u32 = inet_pseudo_sum(src_ip, dst_ip, IP_PROTO_TCP, seg_len);
    sum = inet_sum(r, off, seg_len as usize, sum);
    return inet_fold(sum) == 0xFFFF;
}

// Is `flag` set in a raw flags word (for the connection state machine)?
export fn tcp_flag_set(flags: u16, flag: u16) -> bool {
    return (flags & flag) != 0;
}
