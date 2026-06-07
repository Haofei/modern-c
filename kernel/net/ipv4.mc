// kernel/net/ipv4 — minimal IPv4 (no options, IHL=5) over the typed byte view.
// Arch-neutral. Includes the RFC 1071 ones-complement checksum used by IPv4 and
// ICMP. `at` is the byte offset of the IPv4 header within the buffer.

import "std/dma.mc";

const IP_PROTO_ICMP: u8 = 1;
const IPV4_HDR_LEN: usize = 20;

// One's-complement checksum over [start, start+len) of the buffer (RFC 1071).
export fn ip_checksum(buf: *CpuBuffer, start: usize, len: usize) -> u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while i + 1 < len {
        sum = sum + (read_be16(buf, start + i) as u32);
        i = i + 2;
    }
    if i < len {
        sum = sum + ((read_u8(buf, start + i) as u32) << 8); // last odd byte
    }
    while (sum >> 16) != 0 {
        sum = (sum & 0x0000_FFFF) + (sum >> 16); // fold carries
    }
    return (~sum) as u16;
}

// Write the 20-byte IPv4 header at `at` (with checksum); returns the payload
// offset (`at + 20`).
export fn ipv4_write_header(buf: *CpuBuffer, at: usize, proto: u8, src_ip: u32, dst_ip: u32, payload_len: usize) -> usize {
    write_u8(buf, at + 0, 0x45);  // version 4, IHL 5
    write_u8(buf, at + 1, 0x00);  // DSCP/ECN
    write_be16(buf, at + 2, (IPV4_HDR_LEN + payload_len) as u16); // total length
    write_be16(buf, at + 4, 0);   // identification
    write_be16(buf, at + 6, 0);   // flags/fragment offset
    write_u8(buf, at + 8, 64);    // TTL
    write_u8(buf, at + 9, proto);
    write_be16(buf, at + 10, 0);  // checksum placeholder
    write_be32(buf, at + 12, src_ip);
    write_be32(buf, at + 16, dst_ip);
    let csum: u16 = ip_checksum(buf, at, IPV4_HDR_LEN);
    write_be16(buf, at + 10, csum);
    return at + IPV4_HDR_LEN;
}

// A received IPv4 header is valid when its checksum field re-sums to zero (the
// ones-complement property), so we recompute over the 20-byte header including
// the stored checksum.
export fn ipv4_checksum_valid(buf: *CpuBuffer, at: usize) -> bool {
    let sum: u16 = ip_checksum(buf, at, IPV4_HDR_LEN);
    if sum == 0 {
        return true;
    }
    return false;
}

export fn ipv4_protocol(buf: *CpuBuffer, at: usize) -> u8 {
    return read_u8(buf, at + 9);
}

export fn ipv4_src_ip(buf: *CpuBuffer, at: usize) -> u32 {
    return read_be32(buf, at + 12);
}

export fn ipv4_dst_ip(buf: *CpuBuffer, at: usize) -> u32 {
    return read_be32(buf, at + 16);
}
