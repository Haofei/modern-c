// kernel/net/inet_checksum — the RFC 1071 internet checksum and the IPv4
// pseudo-header sum, shared by UDP and TCP. Operates over a bounds-checked byte
// reader (std/bytes), so summing never runs off the packet.

import "std/bytes.mc";

// 16-bit one's-complement sum over [off, off+len), added to `acc`.
export fn inet_sum(r: *ByteReader, off: usize, len: usize, acc: u32) -> u32 {
    var sum: u32 = acc;
    var i: usize = 0;
    while (i + 1) < len {
        let hi: u32 = br_u8(r, off + i) as u32;
        let lo: u32 = br_u8(r, off + i + 1) as u32;
        sum = sum + ((hi << 8) | lo);
        i = i + 2;
    }
    if i < len {
        let last: u32 = br_u8(r, off + i) as u32;
        sum = sum + (last << 8);
    }
    return sum;
}

// The IPv4 pseudo-header contribution: src/dst addresses, protocol, segment length.
export fn inet_pseudo_sum(src_ip: u32, dst_ip: u32, proto: u32, seg_len: u16) -> u32 {
    var sum: u32 = 0;
    sum = sum + ((src_ip >> 16) & 0x0000_FFFF);
    sum = sum + (src_ip & 0x0000_FFFF);
    sum = sum + ((dst_ip >> 16) & 0x0000_FFFF);
    sum = sum + (dst_ip & 0x0000_FFFF);
    sum = sum + proto;
    sum = sum + (seg_len as u32);
    return sum;
}

// Fold a 32-bit accumulator to 16 bits (carry-around).
export fn inet_fold(sum: u32) -> u16 {
    var s: u32 = sum;
    while (s >> 16) != 0 {
        s = (s & 0x0000_FFFF) + (s >> 16);
    }
    return s as u16;
}
