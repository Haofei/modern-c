// kernel/core/fdt — flattened device-tree (FDT/DTB) parsing: validate the magic, read
// the header fields, and walk the structure block to discover memory. The kernel reads
// the DTB the bootloader/QEMU passes to discover RAM + devices instead of hardcoding
// addresses (start of device discovery / Phase R5).
//
// All multi-byte values in an FDT are big-endian. Every read here routes through
// std/bytes' bounds-checked ByteReader; the structure-block walk uses the *total*
// checked reads (br_try_*) so a malformed/truncated blob fails CLOSED (found=false / no
// read past `len`) rather than trapping the kernel.

import "std/bytes.mc";
import "std/addr.mc";

const FDT_MAGIC: u32 = 0xD00D_FEED;

// Structure-block tokens (each a big-endian u32).
const FDT_BEGIN_NODE: u32 = 1;
const FDT_END_NODE: u32 = 2;
const FDT_PROP: u32 = 3;
const FDT_NOP: u32 = 4;
const FDT_END: u32 = 9;

export fn fdt_valid(blob: PAddr, len: usize) -> bool {
    var r: ByteReader = byte_reader(blob, len);
    return br_be32(&r, 0) == FDT_MAGIC;
}
export fn fdt_totalsize(blob: PAddr, len: usize) -> u32 {
    var r: ByteReader = byte_reader(blob, len);
    return br_be32(&r, 4);
}
export fn fdt_version(blob: PAddr, len: usize) -> u32 {
    var r: ByteReader = byte_reader(blob, len);
    return br_be32(&r, 20);
}

// The result of an FDT /memory walk: whether a usable node was found and its first
// (base, size) reg pair. A 2x u64 + flag struct is ABI-clean to return by value.
struct FdtMemory {
    found: bool,
    base: u64,
    size: u64,
}

// Round `off` up to the next 4-byte boundary (FDT pads names/prop values to u32).
fn fdt_align4(off: usize) -> usize {
    return (off + 3) & ~(3 as usize);
}

// Advance past a NUL-terminated string starting at `off`, returning the offset of the
// byte just past the NUL. Returns err if the string runs off the buffer.
fn fdt_skip_cstr(r: *ByteReader, off: usize) -> Result<usize, BytesError> {
    var i: usize = off;
    while true {
        switch br_try_u8(r, i) {
            ok(c) => {
                i = i + 1;
                if c == 0 {
                    return ok(i);
                }
            }
            err(e) => { return err(.OutOfBounds); }
        }
    }
    return err(.OutOfBounds); // unreachable, keeps the type-checker happy
}

// Name matching. MC string literals can't be carried through a `*const u8` and indexed
// at runtime, so each FDT name we look for is held as a fixed `[N]u8` byte array (arrays
// ARE indexable + bounds-checked) and compared byte-by-byte against the NUL-terminated
// string the blob stores. `plen` is the pattern length EXCLUDING any trailing NUL.

// Exact match: the blob cstring at `soff` equals `pat[0..plen]` and terminates (NUL)
// right after. Used for property names like "#address-cells".
fn fdt_name_eq(r: *ByteReader, soff: usize, pat: [16]u8, plen: usize) -> Result<bool, BytesError> {
    var i: usize = 0;
    while i < plen {
        var b: u8 = 0;
        switch br_try_u8(r, soff + i) {
            ok(v) => { b = v; }
            err(e) => { return err(.OutOfBounds); }
        }
        if b != pat[i] {
            return ok(false);
        }
        i = i + 1;
    }
    // The blob string must end exactly here (next byte is the NUL terminator).
    var term: u8 = 1;
    switch br_try_u8(r, soff + plen) {
        ok(v) => { term = v; }
        err(e) => { return err(.OutOfBounds); }
    }
    return ok(term == 0);
}

// Prefix match: the blob cstring at `soff` BEGINS with `pat[0..plen]` (any suffix). Used
// for the node name "memory" in "memory@80000000".
fn fdt_name_prefix(r: *ByteReader, soff: usize, pat: [16]u8, plen: usize) -> Result<bool, BytesError> {
    var i: usize = 0;
    while i < plen {
        var b: u8 = 0;
        switch br_try_u8(r, soff + i) {
            ok(v) => { b = v; }
            err(e) => { return err(.OutOfBounds); }
        }
        if b != pat[i] {
            return ok(false);
        }
        i = i + 1;
    }
    return ok(true);
}

// The three FDT names we match, as fixed byte arrays (no NUL stored; length tracked
// separately). 16-byte arrays so they share one helper signature.
fn fdt_pat_addr_cells() -> [16]u8 {
    // "#address-cells"
    return .{ 0x23, 0x61, 0x64, 0x64, 0x72, 0x65, 0x73, 0x73, 0x2D, 0x63, 0x65, 0x6C, 0x6C, 0x73, 0, 0 };
}
fn fdt_pat_size_cells() -> [16]u8 {
    // "#size-cells"
    return .{ 0x23, 0x73, 0x69, 0x7A, 0x65, 0x2D, 0x63, 0x65, 0x6C, 0x6C, 0x73, 0, 0, 0, 0, 0 };
}
fn fdt_pat_reg() -> [16]u8 {
    // "reg"
    return .{ 0x72, 0x65, 0x67, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
}
fn fdt_pat_memory() -> [16]u8 {
    // "memory"
    return .{ 0x6D, 0x65, 0x6D, 0x6F, 0x72, 0x79, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
}

fn fdt_name_eq_addr_cells(r: *ByteReader, soff: usize) -> Result<bool, BytesError> {
    let pat: [16]u8 = fdt_pat_addr_cells();
    return fdt_name_eq(r, soff, pat, 14);
}
fn fdt_name_eq_size_cells(r: *ByteReader, soff: usize) -> Result<bool, BytesError> {
    let pat: [16]u8 = fdt_pat_size_cells();
    return fdt_name_eq(r, soff, pat, 11);
}
fn fdt_name_eq_reg(r: *ByteReader, soff: usize) -> Result<bool, BytesError> {
    let pat: [16]u8 = fdt_pat_reg();
    return fdt_name_eq(r, soff, pat, 3);
}
fn fdt_name_starts_memory(r: *ByteReader, soff: usize) -> Result<bool, BytesError> {
    let pat: [16]u8 = fdt_pat_memory();
    return fdt_name_prefix(r, soff, pat, 6);
}

// Read one big-endian cell (u32) at `off`; OutOfBounds-safe.
fn fdt_read_cell(r: *ByteReader, off: usize) -> Result<u32, BytesError> {
    return br_try_be32(r, off);
}

// Decode `cells` consecutive big-endian u32 cells starting at `off` into a u64 (the FDT
// encoding for an address or size that spans 1 or 2 cells). More than 2 cells would not
// fit a u64 cleanly; we only ever request 1 or 2 here.
fn fdt_read_cells_u64(r: *ByteReader, off: usize, cells: u32) -> Result<u64, BytesError> {
    var acc: u64 = 0;
    var i: u32 = 0;
    while i < cells {
        var c: u32 = 0;
        switch fdt_read_cell(r, off + (i as usize) * 4) {
            ok(v) => { c = v; }
            err(e) => { return err(.OutOfBounds); }
        }
        acc = (acc << 32) | (c as u64);
        i = i + 1;
    }
    return ok(acc);
}

// Walk the FDT structure block and decode the first /memory node's first reg pair.
//
// Strategy: a single linear pass over the structure-block token stream. We track depth
// so we can read the ROOT node's #address-cells / #size-cells (depth 1, the immediate
// children of the implicit pre-root) before we encounter the memory node. When we enter
// a node at depth 1 whose name starts with "memory", we record that we're inside it; its
// `reg` property is then decoded with the root's cell counts.
export fn fdt_memory(blob: PAddr, len: usize) -> FdtMemory {
    var out: FdtMemory = .{ .found = false, .base = 0, .size = 0 };

    if !fdt_valid(blob, len) {
        return out;
    }

    var r: ByteReader = byte_reader(blob, len);

    // Header fields (fixed offsets, present iff totalsize-consistent; use try-reads so a
    // truncated header fails closed).
    var off_dt_struct: u32 = 0;
    var off_dt_strings: u32 = 0;
    switch br_try_be32(&r, 8) { ok(v) => { off_dt_struct = v; } err(e) => { return out; } }
    switch br_try_be32(&r, 12) { ok(v) => { off_dt_strings = v; } err(e) => { return out; } }

    // FDT spec defaults when a node omits the cell-count props.
    var addr_cells: u32 = 2;
    var size_cells: u32 = 2;

    var pos: usize = off_dt_struct as usize;
    var depth: u32 = 0;          // 0 = before/at the implicit pre-root boundary
    var in_memory: bool = false; // currently inside a depth-1 node named memory*

    // Bound the walk to the number of tokens that could fit in the blob (defence in
    // depth against a malformed stream with no FDT_END): each iteration consumes >= 4
    // bytes, so len/4 iterations is a safe ceiling.
    var guard: usize = len / 4 + 1;

    while guard > 0 {
        guard = guard - 1;
        var tok: u32 = 0;
        switch br_try_be32(&r, pos) {
            ok(v) => { tok = v; }
            err(e) => { return out; }
        }
        pos = pos + 4;

        if tok == FDT_BEGIN_NODE {
            depth = depth + 1;
            // The node name is a NUL-terminated string at `pos`, padded to 4 bytes.
            let name_off: usize = pos;
            switch fdt_skip_cstr(&r, pos) {
                ok(nxt) => { pos = fdt_align4(nxt); }
                err(e) => { return out; }
            }
            // The /memory node is a direct child of the root, i.e. depth 2 (root itself
            // is depth 1). Only flag it there, so a "memory-controller@..." nested deeper
            // or the root's own name can't be mistaken for it.
            if depth == 2 {
                switch fdt_name_starts_memory(&r, name_off) {
                    ok(m) => { in_memory = m; }
                    err(e) => { return out; }
                }
            }
        } else if tok == FDT_END_NODE {
            if depth == 0 {
                return out; // malformed: unbalanced end
            }
            if depth == 2 {
                in_memory = false; // leaving the depth-2 child we may have flagged
            }
            depth = depth - 1;
        } else if tok == FDT_PROP {
            var plen: u32 = 0;
            var nameoff: u32 = 0;
            switch br_try_be32(&r, pos) { ok(v) => { plen = v; } err(e) => { return out; } }
            switch br_try_be32(&r, pos + 4) { ok(v) => { nameoff = v; } err(e) => { return out; } }
            let val_off: usize = pos + 8;
            let soff: usize = (off_dt_strings as usize) + (nameoff as usize);

            // Root-node cell counts: read at depth 1 (root's direct props). The root
            // node is the first BEGIN_NODE (an empty name), so its props are at depth 1.
            if depth == 1 && !in_memory {
                switch fdt_name_eq_addr_cells(&r, soff) {
                    ok(hit) => {
                        if hit {
                            switch fdt_read_cell(&r, val_off) { ok(v) => { addr_cells = v; } err(e) => { return out; } }
                        }
                    }
                    err(e) => { return out; }
                }
                switch fdt_name_eq_size_cells(&r, soff) {
                    ok(hit) => {
                        if hit {
                            switch fdt_read_cell(&r, val_off) { ok(v) => { size_cells = v; } err(e) => { return out; } }
                        }
                    }
                    err(e) => { return out; }
                }
            }

            // Inside a memory node: decode reg = <base(addr_cells)> <size(size_cells)>.
            if in_memory {
                switch fdt_name_eq_reg(&r, soff) {
                    ok(hit) => {
                        if hit {
                            var base: u64 = 0;
                            var size: u64 = 0;
                            switch fdt_read_cells_u64(&r, val_off, addr_cells) {
                                ok(v) => { base = v; }
                                err(e) => { return out; }
                            }
                            switch fdt_read_cells_u64(&r, val_off + (addr_cells as usize) * 4, size_cells) {
                                ok(v) => { size = v; }
                                err(e) => { return out; }
                            }
                            out.found = true;
                            out.base = base;
                            out.size = size;
                            return out; // first memory reg pair wins
                        }
                    }
                    err(e) => { return out; }
                }
            }

            // Advance past the property value, padded to a 4-byte boundary.
            pos = fdt_align4(val_off + (plen as usize));
        } else if tok == FDT_NOP {
            // nothing; already advanced past the token
        } else if tok == FDT_END {
            return out; // end of structure block, no memory node decoded
        } else {
            return out; // unknown token => malformed, fail closed
        }
    }

    return out;
}

// ----- scalar entry points for the C boot runtime (clean C/MC ABI) -----
//
// The S-mode boot runtime computes the blob length from the header totalsize and then
// asks for each field separately, keeping the C side free of MC struct layout knowledge.

export fn fdt_boot_ok_pa(blob: PAddr) -> bool {
    if !fdt_valid(blob, 8) {
        return false; // can't even read the header => not OK
    }
    let total: usize = fdt_totalsize(blob, 8) as usize;
    let m: FdtMemory = fdt_memory(blob, total);
    return m.found && m.base != 0 && m.size != 0;
}

export fn fdt_boot_base_pa(blob: PAddr) -> u64 {
    if !fdt_valid(blob, 8) {
        return 0;
    }
    let total: usize = fdt_totalsize(blob, 8) as usize;
    let m: FdtMemory = fdt_memory(blob, total);
    return m.base;
}

export fn fdt_boot_size_pa(blob: PAddr) -> u64 {
    if !fdt_valid(blob, 8) {
        return 0;
    }
    let total: usize = fdt_totalsize(blob, 8) as usize;
    let m: FdtMemory = fdt_memory(blob, total);
    return m.size;
}
