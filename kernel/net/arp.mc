// kernel/net/arp — minimal ARP (request + reply) over Ethernet. Arch-neutral.
// Enough to ARP a peer and answer ARP requests for our address. `at` is the byte
// offset of the Ethernet frame within the buffer.

import "ethernet.mc";
import "std/dma.mc";

const ARP_OP_REQUEST: u16 = 1;
const ARP_OP_REPLY: u16 = 2;
const ARP_FRAME_LEN: usize = 42; // 14 (eth) + 28 (arp)

// ARP body lives 14 bytes into the Ethernet frame.
fn arp_write_body(buf: *CpuBuffer, at: usize, oper: u16, sha: *MacAddr, spa: u32, tha: *MacAddr, tpa: u32) -> void {
    let b: usize = at + 14;
    write_be16(buf, b + 0, 1);              // htype = Ethernet
    write_be16(buf, b + 2, ETHERTYPE_IPV4); // ptype = IPv4
    write_u8(buf, b + 4, 6);                // hlen
    write_u8(buf, b + 5, 4);                // plen
    write_be16(buf, b + 6, oper);
    eth_write_mac(buf, b + 8, sha);         // sender hardware addr
    write_be32(buf, b + 14, spa);           // sender protocol addr
    eth_write_mac(buf, b + 18, tha);        // target hardware addr
    write_be32(buf, b + 24, tpa);           // target protocol addr
}

// Build a broadcast ARP request "who has target_ip?"; returns the frame length.
export fn arp_write_request(buf: *CpuBuffer, at: usize, src_mac: *MacAddr, src_ip: u32, target_ip: u32) -> usize {
    var bcast: MacAddr = mac_broadcast();
    var zero: MacAddr = .{ .bytes = .{ 0, 0, 0, 0, 0, 0 } };
    eth_write_header(buf, at, &bcast, src_mac, ETHERTYPE_ARP);
    arp_write_body(buf, at, ARP_OP_REQUEST, src_mac, src_ip, &zero, target_ip);
    return ARP_FRAME_LEN;
}

// Build an ARP reply to `req_mac`/`req_ip`; returns the frame length.
export fn arp_write_reply(buf: *CpuBuffer, at: usize, src_mac: *MacAddr, src_ip: u32, req_mac: *MacAddr, req_ip: u32) -> usize {
    eth_write_header(buf, at, req_mac, src_mac, ETHERTYPE_ARP);
    arp_write_body(buf, at, ARP_OP_REPLY, src_mac, src_ip, req_mac, req_ip);
    return ARP_FRAME_LEN;
}

export fn arp_oper(buf: *CpuBuffer, at: usize) -> u16 {
    return read_be16(buf, at + 14 + 6);
}

export fn arp_sender_ip(buf: *CpuBuffer, at: usize) -> u32 {
    return read_be32(buf, at + 14 + 14);
}

export fn arp_target_ip(buf: *CpuBuffer, at: usize) -> u32 {
    return read_be32(buf, at + 14 + 24);
}
