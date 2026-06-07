// kernel/net/packet — typed network addresses and a packet cursor.
//
// Centralizes the endianness/offset handling that the protocol modules otherwise
// hand-roll: `Ipv4Addr` is a typed address (so it can't be confused with another
// `u32`), and `PacketCursor` carries a section base + the frame's received length
// so reads are relative and bounds-aware. The big-endian byte primitives live in
// std/dma's typed buffer view; this layer gives them names and bounds.

import "std/dma.mc";

// A typed IPv4 address (network byte order is applied at write time).
struct Ipv4Addr {
    raw: u32,
}

export fn ipv4(a: u8, b: u8, c: u8, d: u8) -> Ipv4Addr {
    let v: u32 = ((a as u32) << 24) | ((b as u32) << 16) | ((c as u32) << 8) | (d as u32);
    return .{ .raw = v };
}

export fn ipv4_from_u32(raw: u32) -> Ipv4Addr {
    return .{ .raw = raw };
}

export fn ipv4_eq(x: *Ipv4Addr, y: *Ipv4Addr) -> bool {
    return x.raw == y.raw;
}

// A cursor into a frame within a cpu-owned buffer: `base` is where this section
// starts, `limit` is the buffer's received length. Reads/writes are relative to
// `base`; `has(n)` checks that `n` bytes are available before parsing.
struct PacketCursor {
    base: usize,
    limit: usize,
}

export fn cursor(buf: *CpuBuffer, base: usize) -> PacketCursor {
    return .{ .base = base, .limit = cpu_len(buf) };
}

// Does the frame hold at least `n` bytes past this cursor's base?
export fn has(c: *PacketCursor, n: usize) -> bool {
    return (c.base + n) <= c.limit;
}

// A sub-cursor `offset` bytes further in (e.g. the IPv4 header within a frame).
export fn at(c: *PacketCursor, offset: usize) -> PacketCursor {
    return .{ .base = c.base + offset, .limit = c.limit };
}

export fn put_u8(c: *PacketCursor, buf: *CpuBuffer, off: usize, v: u8) -> void {
    write_u8(buf, c.base + off, v);
}
export fn put_be16(c: *PacketCursor, buf: *CpuBuffer, off: usize, v: u16) -> void {
    write_be16(buf, c.base + off, v);
}
export fn put_be32(c: *PacketCursor, buf: *CpuBuffer, off: usize, v: u32) -> void {
    write_be32(buf, c.base + off, v);
}
export fn get_u8(c: *PacketCursor, buf: *CpuBuffer, off: usize) -> u8 {
    return read_u8(buf, c.base + off);
}
export fn get_be16(c: *PacketCursor, buf: *CpuBuffer, off: usize) -> u16 {
    return read_be16(buf, c.base + off);
}
export fn get_be32(c: *PacketCursor, buf: *CpuBuffer, off: usize) -> u32 {
    return read_be32(buf, c.base + off);
}
