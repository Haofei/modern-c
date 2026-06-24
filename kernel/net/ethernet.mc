// kernel/net/ethernet — Ethernet II framing over the typed DMA byte view.
// Arch-neutral: it only reads/writes bytes in a cpu-owned buffer. Every helper
// takes `at`, the byte offset where the Ethernet frame begins (e.g. after a
// 12-byte virtio-net header), so the frame can be placed anywhere in the buffer.

import "std/alloc/dma.mc";

const ETH_HDR_LEN: usize = 14;
const ETHERTYPE_ARP: u16 = 0x0806;
const ETHERTYPE_IPV4: u16 = 0x0800;

struct MacAddr {
    bytes: [6]u8,
}

export fn mac_broadcast() -> MacAddr {
    return .{ .bytes = .{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF } };
}

// Write a MAC at `offset` in the buffer.
export fn eth_write_mac(buf: *CpuBuffer, offset: usize, mac: *MacAddr) -> void {
    var i: usize = 0;
    while i < 6 {
        write_u8(buf, offset + i, mac.bytes[i]);
        i = i + 1;
    }
}

// Read a MAC from `offset`.
export fn eth_read_mac(buf: *CpuBuffer, offset: usize) -> MacAddr {
    var out: MacAddr = .{ .bytes = .{ 0, 0, 0, 0, 0, 0 } };
    var i: usize = 0;
    while i < 6 {
        out.bytes[i] = read_u8(buf, offset + i);
        i = i + 1;
    }
    return out;
}

// Write the 14-byte Ethernet header at `at`; returns the payload offset.
export fn eth_write_header(buf: *CpuBuffer, at: usize, dst: *MacAddr, src: *MacAddr, ethertype: u16) -> usize {
    eth_write_mac(buf, at + 0, dst);
    eth_write_mac(buf, at + 6, src);
    write_be16(buf, at + 12, ethertype);
    return at + ETH_HDR_LEN;
}

// The ethertype of a frame located at `at`.
export fn eth_ethertype(buf: *CpuBuffer, at: usize) -> u16 {
    return read_be16(buf, at + 12);
}
