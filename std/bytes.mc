// std/bytes — a bounds-checked byte reader over a raw memory region.
//
// Positional reads of fixed-width integers in either endianness; every access is
// validated against the region length, so a read past the end can NEVER run wild
// off the buffer. Used for parsing structured byte streams (ELF headers, on-wire
// packets) without open-coded, unchecked offset arithmetic. The raw loads are
// concentrated here behind the bounds check.
//
// Two read disciplines over the SAME bounds check (`br_has`), pick per call site:
//
//   * trapping reads (`br_u8`/`br_be16`/…): an out-of-bounds offset hits
//     `unreachable` — a hard abort. Use only when the caller has already proven the
//     offset in range (e.g. a fixed header whose presence was length-checked up
//     front). This is the kernel's last-resort safety net: it converts a missed
//     bounds check into an immediate, contained trap rather than a wild read.
//
//   * total checked reads (`br_try_u8`/`br_try_be16`/…): return
//     `Result<T, BytesError>` (OutOfBounds on overflow) and NEVER trap. This is the
//     "safe reader" parsers over ATTACKER-CONTROLLED input use: every read is a
//     total function over the finite buffer, so a truncated/malformed packet is
//     rejected cleanly with a typed error instead of crashing the parser. A parser
//     built only from `br_try_*` cannot over-read no matter what the input claims.
//
// Both disciplines route through `br_has`, so neither can ever read past `len`.

import "std/addr.mc";

struct ByteReader {
    base: PAddr,
    len: usize,
}

// The only failure a checked read can report: the requested [off, off+n) does not
// lie within the buffer (off+n > len, including the overflow case).
enum BytesError {
    OutOfBounds,
}

export fn byte_reader(base: PAddr, len: usize) -> ByteReader {
    return .{ .base = base, .len = len };
}

export fn br_len(r: *ByteReader) -> usize {
    return r.len;
}

// Are there at least `n` bytes available starting at `off` (no overflow)?
export fn br_has(r: *ByteReader, off: usize, n: usize) -> bool {
    if off > r.len {
        return false;
    }
    let room: usize = r.len - off;
    return n <= room;
}

fn br_check(r: *ByteReader, off: usize, n: usize) -> void {
    if !br_has(r, off, n) {
        unreachable; // read past end of buffer
    }
}

export fn br_u8(r: *ByteReader, off: usize) -> u8 {
    br_check(r, off, 1);
    unsafe {
        return raw.load<u8>(pa_offset(r.base, off));
    }
}

export fn br_le16(r: *ByteReader, off: usize) -> u16 {
    let b0: u16 = br_u8(r, off) as u16;
    let b1: u16 = br_u8(r, off + 1) as u16;
    return b0 | (b1 << 8);
}

export fn br_le32(r: *ByteReader, off: usize) -> u32 {
    let b0: u32 = br_u8(r, off) as u32;
    let b1: u32 = br_u8(r, off + 1) as u32;
    let b2: u32 = br_u8(r, off + 2) as u32;
    let b3: u32 = br_u8(r, off + 3) as u32;
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
}

export fn br_le64(r: *ByteReader, off: usize) -> u64 {
    let lo: u64 = br_le32(r, off) as u64;
    let hi: u64 = br_le32(r, off + 4) as u64;
    return lo | (hi << 32);
}

export fn br_be16(r: *ByteReader, off: usize) -> u16 {
    let b0: u16 = br_u8(r, off) as u16;
    let b1: u16 = br_u8(r, off + 1) as u16;
    return (b0 << 8) | b1;
}

export fn br_be32(r: *ByteReader, off: usize) -> u32 {
    let b0: u32 = br_u8(r, off) as u32;
    let b1: u32 = br_u8(r, off + 1) as u32;
    let b2: u32 = br_u8(r, off + 2) as u32;
    let b3: u32 = br_u8(r, off + 3) as u32;
    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
}

// ----- total checked reads: return a typed error, never trap -----
//
// These are the "safe reader" for parsing attacker-controlled bytes. Each validates
// the FULL width [off, off+size) up front (so it never partially reads before
// failing) and returns OutOfBounds rather than trapping. Once `br_try_*` succeeds,
// the bytes are known present; the trapping `br_*` below then cannot abort.

// Raw single-byte load WITHOUT the bounds check — private; only ever reached after a
// caller has proven [off, off+1) in range (via br_has / a width check above).
fn br_load_u8(r: *ByteReader, off: usize) -> u8 {
    unsafe {
        return raw.load<u8>(pa_offset(r.base, off));
    }
}

export fn br_try_u8(r: *ByteReader, off: usize) -> Result<u8, BytesError> {
    if !br_has(r, off, 1) {
        return err(.OutOfBounds);
    }
    return ok(br_load_u8(r, off));
}

export fn br_try_be16(r: *ByteReader, off: usize) -> Result<u16, BytesError> {
    if !br_has(r, off, 2) {
        return err(.OutOfBounds);
    }
    let b0: u16 = br_load_u8(r, off) as u16;
    let b1: u16 = br_load_u8(r, off + 1) as u16;
    return ok((b0 << 8) | b1);
}

export fn br_try_be32(r: *ByteReader, off: usize) -> Result<u32, BytesError> {
    if !br_has(r, off, 4) {
        return err(.OutOfBounds);
    }
    let b0: u32 = br_load_u8(r, off) as u32;
    let b1: u32 = br_load_u8(r, off + 1) as u32;
    let b2: u32 = br_load_u8(r, off + 2) as u32;
    let b3: u32 = br_load_u8(r, off + 3) as u32;
    return ok((b0 << 24) | (b1 << 16) | (b2 << 8) | b3);
}

export fn br_try_le16(r: *ByteReader, off: usize) -> Result<u16, BytesError> {
    if !br_has(r, off, 2) {
        return err(.OutOfBounds);
    }
    let b0: u16 = br_load_u8(r, off) as u16;
    let b1: u16 = br_load_u8(r, off + 1) as u16;
    return ok(b0 | (b1 << 8));
}

export fn br_try_le32(r: *ByteReader, off: usize) -> Result<u32, BytesError> {
    if !br_has(r, off, 4) {
        return err(.OutOfBounds);
    }
    let b0: u32 = br_load_u8(r, off) as u32;
    let b1: u32 = br_load_u8(r, off + 1) as u32;
    let b2: u32 = br_load_u8(r, off + 2) as u32;
    let b3: u32 = br_load_u8(r, off + 3) as u32;
    return ok(b0 | (b1 << 8) | (b2 << 16) | (b3 << 24));
}

export fn br_try_le64(r: *ByteReader, off: usize) -> Result<u64, BytesError> {
    if !br_has(r, off, 8) {
        return err(.OutOfBounds);
    }
    var lo: u32 = 0;
    var hi: u32 = 0;
    switch br_try_le32(r, off) { ok(v) => { lo = v; } err(e) => { return err(.OutOfBounds); } }
    switch br_try_le32(r, off + 4) { ok(v) => { hi = v; } err(e) => { return err(.OutOfBounds); } }
    return ok((lo as u64) | ((hi as u64) << 32));
}

// Copy `n` bytes from the reader (starting at `off`) into the physical region `dst`.
// Reads are bounds-checked against the reader; the raw store is the single unsafe
// edge — so callers (the ELF loader, …) don't hand-roll a `while { raw.store }` loop.
export fn br_copy_to(r: *ByteReader, off: usize, dst: PAddr, n: usize) -> void {
    var i: usize = 0;
    while i < n {
        let b: u8 = br_u8(r, off + i); // bounds-checked
        unsafe {
            raw.store<u8>(pa_offset(dst, i), b);
        }
        i = i + 1;
    }
}

// ----- a bounds-checked writer over a raw region (the dual of ByteReader) -----

struct ByteWriter {
    base: PAddr,
    len: usize,
}

export fn byte_writer(base: PAddr, len: usize) -> ByteWriter {
    return .{ .base = base, .len = len };
}

fn bw_check(w: *ByteWriter, off: usize, n: usize) -> void {
    if off > w.len {
        unreachable; // write past end of buffer
    }
    let room: usize = w.len - off;
    if n > room {
        unreachable;
    }
}

export fn bw_u8(w: *ByteWriter, off: usize, value: u8) -> void {
    bw_check(w, off, 1);
    unsafe {
        raw.store<u8>(pa_offset(w.base, off), value);
    }
}

export fn bw_be16(w: *ByteWriter, off: usize, value: u16) -> void {
    bw_check(w, off, 2); // check the full width up front: never partially store before trapping
    bw_u8(w, off, (value >> 8) as u8);
    bw_u8(w, off + 1, (value & 0x00FF) as u8);
}

export fn bw_be32(w: *ByteWriter, off: usize, value: u32) -> void {
    bw_check(w, off, 4); // check the full width up front: never partially store before trapping
    bw_u8(w, off, (value >> 24) as u8);
    bw_u8(w, off + 1, ((value >> 16) & 0x0000_00FF) as u8);
    bw_u8(w, off + 2, ((value >> 8) & 0x0000_00FF) as u8);
    bw_u8(w, off + 3, (value & 0x0000_00FF) as u8);
}
