// kernel/net/icmp — minimal ICMP echo (ping) over IPv4. Arch-neutral. Builds and
// parses complete Ethernet+IPv4+ICMP frames over the typed byte view. `at` is the
// byte offset of the Ethernet frame within the buffer.

import "ethernet.mc";
import "ipv4.mc";
import "std/alloc/dma.mc";

const ICMP_ECHO_REQUEST: u8 = 8;
const ICMP_ECHO_REPLY: u8 = 0;
const ICMP_HDR_LEN: usize = 8;

// Frame layout offsets from the Ethernet frame start.
const IP_AT: usize = 14;        // after the Ethernet header
const ICMP_AT: usize = 34;      // after eth(14) + ipv4(20)
const ICMP_FRAME_LEN: usize = 42; // eth + ipv4 + icmp (no payload)

fn icmp_write(buf: *CpuBuffer, at: usize, kind: u8, ident: u16, seq: u16) -> void {
    let c: usize = at + ICMP_AT;
    write_u8(buf, c + 0, kind);
    write_u8(buf, c + 1, 0);        // code
    write_be16(buf, c + 2, 0);      // checksum placeholder
    write_be16(buf, c + 4, ident);
    write_be16(buf, c + 6, seq);
    let csum: u16 = ip_checksum(buf, c, ICMP_HDR_LEN);
    write_be16(buf, c + 2, csum);
}

// Build an ICMP echo *request* (eth + ipv4 + icmp); returns the frame length.
export fn icmp_write_echo_request(buf: *CpuBuffer, at: usize, src_mac: *MacAddr, dst_mac: *MacAddr, src_ip: u32, dst_ip: u32, ident: u16, seq: u16) -> usize {
    eth_write_header(buf, at, dst_mac, src_mac, ETHERTYPE_IPV4);
    ipv4_write_header(buf, at + IP_AT, IP_PROTO_ICMP, src_ip, dst_ip, ICMP_HDR_LEN);
    icmp_write(buf, at, ICMP_ECHO_REQUEST, ident, seq);
    return ICMP_FRAME_LEN;
}

// Build an ICMP echo *reply* to a peer (answers a ping).
export fn icmp_write_echo_reply(buf: *CpuBuffer, at: usize, src_mac: *MacAddr, dst_mac: *MacAddr, src_ip: u32, dst_ip: u32, ident: u16, seq: u16) -> usize {
    eth_write_header(buf, at, dst_mac, src_mac, ETHERTYPE_IPV4);
    ipv4_write_header(buf, at + IP_AT, IP_PROTO_ICMP, src_ip, dst_ip, ICMP_HDR_LEN);
    icmp_write(buf, at, ICMP_ECHO_REPLY, ident, seq);
    return ICMP_FRAME_LEN;
}

// The ICMP type of a received IPv4/ICMP frame at `at`.
export fn icmp_type(buf: *CpuBuffer, at: usize) -> u8 {
    return read_u8(buf, at + ICMP_AT);
}

export fn icmp_ident(buf: *CpuBuffer, at: usize) -> u16 {
    return read_be16(buf, at + ICMP_AT + 4);
}

export fn icmp_seq(buf: *CpuBuffer, at: usize) -> u16 {
    return read_be16(buf, at + ICMP_AT + 6);
}
