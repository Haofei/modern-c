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

// ============================================================================
// Phase R5 device discovery: compatible-string finders.
//
// Unlike /memory (a depth-2 child of the root), real devices on QEMU virt live
// under /soc (depth 2), so they are at depth 3+, and their `reg` must be decoded
// with the PARENT node's #address-cells/#size-cells — which /soc itself
// redefines (to 2/2 here, but /cpus uses 1/0 and /platform-bus 1/1 in the same
// tree). So we maintain a small DEPTH-INDEXED cell-count stack instead of only
// reading the root's counts. On BEGIN_NODE at depth d we inherit cells_at[d-1];
// a #address-cells/#size-cells prop overwrites the CURRENT depth's entry; a
// node's reg is decoded with cells_at[depth-1] (its parent). The stack is a
// fixed [FDT_MAX_DEPTH]u32; a tree deeper than that fails CLOSED.
// ============================================================================

const FDT_MAX_DEPTH: usize = 16;

// The result of a device-node lookup: whether a matching node was found and its
// first reg (base, size) pair, decoded with the parent's cell counts.
struct FdtDevice {
    found: bool,
    base: u64,
    size: u64,
}

// A `compatible` value is one-or-more NUL-terminated strings concatenated inside
// `plen` bytes. Return true iff ANY contained string equals pat[0..plen_pat]
// exactly. We walk the value byte-by-byte: at the start of each contained
// string, try an exact compare; on mismatch, skip to just past the next NUL and
// retry. Everything is bounds-guarded against `vend` (value end) and the reader.
fn fdt_compat_contains(
    r: *ByteReader,
    voff: usize,
    vlen: usize,
    pat: [16]u8,
    plen_pat: usize,
) -> Result<bool, BytesError> {
    let vend: usize = voff + vlen;
    var soff: usize = voff;
    while soff < vend {
        // Try to match pat exactly at this contained-string start.
        var i: usize = 0;
        var matched: bool = true;
        while i < plen_pat {
            if soff + i >= vend {
                matched = false;
                break;
            }
            var b: u8 = 0;
            switch br_try_u8(r, soff + i) {
                ok(v) => { b = v; }
                err(e) => { return err(.OutOfBounds); }
            }
            if b != pat[i] {
                matched = false;
                break;
            }
            i = i + 1;
        }
        if matched {
            // The contained string must terminate (NUL) exactly after plen_pat.
            if soff + plen_pat >= vend {
                // Pattern ran to the value end without a NUL: only a match if the
                // value's final byte region is exactly the pattern + NUL. Since
                // vlen always includes the trailing NUL of the last string, the
                // terminator check below covers this; here it means truncation.
                return ok(false);
            }
            var term: u8 = 1;
            switch br_try_u8(r, soff + plen_pat) {
                ok(v) => { term = v; }
                err(e) => { return err(.OutOfBounds); }
            }
            if term == 0 {
                return ok(true);
            }
        }
        // Advance to just past this contained string's NUL.
        switch fdt_skip_cstr(r, soff) {
            ok(nxt) => {
                if nxt <= soff || nxt > vend {
                    return ok(false); // ran past the value => no further strings
                }
                soff = nxt;
            }
            err(e) => { return ok(false); }
        }
    }
    return ok(false);
}

// "compatible" property-name pattern (for prop-name matching against strings).
fn fdt_pat_compatible() -> [16]u8 {
    // "compatible"
    return .{ 0x63, 0x6F, 0x6D, 0x70, 0x61, 0x74, 0x69, 0x62, 0x6C, 0x65, 0, 0, 0, 0, 0, 0 };
}
fn fdt_name_eq_compatible(r: *ByteReader, soff: usize) -> Result<bool, BytesError> {
    let pat: [16]u8 = fdt_pat_compatible();
    return fdt_name_eq(r, soff, pat, 10);
}

// Device compatible-string target patterns (confirmed against the real QEMU virt
// DTB via `-machine virt,dumpdtb=`). Stored as fixed [16]u8 byte arrays because
// MC cannot index a string-literal *const u8 at runtime.
fn fdt_pat_ns16550a() -> [16]u8 {
    // "ns16550a"
    return .{ 0x6E, 0x73, 0x31, 0x36, 0x35, 0x35, 0x30, 0x61, 0, 0, 0, 0, 0, 0, 0, 0 };
}
// The PLIC node advertises two compatible strings: "sifive,plic-1.0.0" (17 bytes,
// which does NOT fit a 16-byte pattern array) and the shorter "riscv,plic0" alias.
// We match the latter, which the same node also advertises — fdt_compat_contains
// scans EVERY contained string, so matching either alias finds the PLIC node.
fn fdt_pat_plic_riscv() -> [16]u8 {
    // "riscv,plic0"
    return .{ 0x72, 0x69, 0x73, 0x63, 0x76, 0x2C, 0x70, 0x6C, 0x69, 0x63, 0x30, 0, 0, 0, 0, 0 };
}
fn fdt_pat_virtio_mmio() -> [16]u8 {
    // "virtio,mmio"
    return .{ 0x76, 0x69, 0x72, 0x74, 0x69, 0x6F, 0x2C, 0x6D, 0x6D, 0x69, 0x6F, 0, 0, 0, 0, 0 };
}

// Core walk: find the FIRST node whose `compatible` contains the target pattern,
// decode its first reg (base,size) pair with the parent depth's cell counts.
// If `nth` > 0, skip that many matches first (used to confirm determinism /
// pick a specific instance); nth=0 returns the first match.
fn fdt_find_compatible_impl(
    blob: PAddr,
    len: usize,
    pat: [16]u8,
    plen_pat: usize,
) -> FdtDevice {
    var out: FdtDevice = .{ .found = false, .base = 0, .size = 0 };

    if !fdt_valid(blob, len) {
        return out;
    }
    var r: ByteReader = byte_reader(blob, len);

    var off_dt_struct: u32 = 0;
    var off_dt_strings: u32 = 0;
    switch br_try_be32(&r, 8) { ok(v) => { off_dt_struct = v; } err(e) => { return out; } }
    switch br_try_be32(&r, 12) { ok(v) => { off_dt_strings = v; } err(e) => { return out; } }

    // Depth-indexed cell-count stack. Index 0 is the implicit pre-root; the root
    // is depth 1. Initialise depth-0 to the spec default 2/2 so depth-1 inherits
    // it (the root usually sets its own anyway).
    var addr_cells_at: [16]u32 = .{ 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2 };
    var size_cells_at: [16]u32 = .{ 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2 };

    var pos: usize = off_dt_struct as usize;
    var depth: u32 = 0;
    var node_is_match: bool = false; // current node's compatible contains target
    // Within a node, `reg` may appear BEFORE `compatible` (it does on QEMU virt).
    // So we cannot decode reg the instant we see it. Instead we REMEMBER this
    // node's reg value offset (have_reg) and decode it once we know the node
    // matches — whichever of the two props comes second triggers the emit.
    var have_reg: bool = false;
    var reg_voff: usize = 0;

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
            if (depth as usize) >= FDT_MAX_DEPTH {
                return out; // tree deeper than the cell stack: fail closed
            }
            switch fdt_skip_cstr(&r, pos) {
                ok(nxt) => { pos = fdt_align4(nxt); }
                err(e) => { return out; }
            }
            // Inherit parent's cell counts into this depth.
            let d: usize = depth as usize;
            addr_cells_at[d] = addr_cells_at[d - 1];
            size_cells_at[d] = size_cells_at[d - 1];
            node_is_match = false;
            have_reg = false;
            reg_voff = 0;
        } else if tok == FDT_END_NODE {
            if depth == 0 {
                return out;
            }
            depth = depth - 1;
            node_is_match = false;
            have_reg = false;
            reg_voff = 0;
        } else if tok == FDT_PROP {
            var plen: u32 = 0;
            var nameoff: u32 = 0;
            switch br_try_be32(&r, pos) { ok(v) => { plen = v; } err(e) => { return out; } }
            switch br_try_be32(&r, pos + 4) { ok(v) => { nameoff = v; } err(e) => { return out; } }
            let val_off: usize = pos + 8;
            let soff: usize = (off_dt_strings as usize) + (nameoff as usize);
            let d: usize = depth as usize;

            // #address-cells / #size-cells overwrite the CURRENT depth's entry.
            if d >= 1 && d < FDT_MAX_DEPTH {
                switch fdt_name_eq_addr_cells(&r, soff) {
                    ok(hit) => {
                        if hit {
                            switch fdt_read_cell(&r, val_off) { ok(v) => { addr_cells_at[d] = v; } err(e) => { return out; } }
                        }
                    }
                    err(e) => { return out; }
                }
                switch fdt_name_eq_size_cells(&r, soff) {
                    ok(hit) => {
                        if hit {
                            switch fdt_read_cell(&r, val_off) { ok(v) => { size_cells_at[d] = v; } err(e) => { return out; } }
                        }
                    }
                    err(e) => { return out; }
                }
            }

            // compatible: does any contained string equal the target?
            switch fdt_name_eq_compatible(&r, soff) {
                ok(hit) => {
                    if hit {
                        switch fdt_compat_contains(&r, val_off, plen as usize, pat, plen_pat) {
                            ok(m) => { if m { node_is_match = true; } }
                            err(e) => { return out; }
                        }
                    }
                }
                err(e) => { return out; }
            }

            // reg: remember its value offset (it may precede `compatible`).
            switch fdt_name_eq_reg(&r, soff) {
                ok(hit) => {
                    if hit {
                        have_reg = true;
                        reg_voff = val_off;
                    }
                }
                err(e) => { return out; }
            }

            // Once BOTH a target match and a reg are known for this node, decode
            // reg with the PARENT depth's cell counts (cells_at[depth-1]) and
            // return — the first matching node wins.
            if node_is_match && have_reg && d >= 1 {
                let pac: u32 = addr_cells_at[d - 1];
                let psc: u32 = size_cells_at[d - 1];
                var base: u64 = 0;
                var size: u64 = 0;
                switch fdt_read_cells_u64(&r, reg_voff, pac) {
                    ok(v) => { base = v; }
                    err(e) => { return out; }
                }
                switch fdt_read_cells_u64(&r, reg_voff + (pac as usize) * 4, psc) {
                    ok(v) => { size = v; }
                    err(e) => { return out; }
                }
                out.found = true;
                out.base = base;
                out.size = size;
                return out;
            }

            pos = fdt_align4(val_off + (plen as usize));
        } else if tok == FDT_NOP {
            // nothing
        } else if tok == FDT_END {
            return out;
        } else {
            return out;
        }
    }
    return out;
}

// Count nodes whose `compatible` contains the target pattern.
fn fdt_count_compatible_impl(
    blob: PAddr,
    len: usize,
    pat: [16]u8,
    plen_pat: usize,
) -> u32 {
    var count: u32 = 0;
    if !fdt_valid(blob, len) {
        return 0;
    }
    var r: ByteReader = byte_reader(blob, len);

    var off_dt_struct: u32 = 0;
    var off_dt_strings: u32 = 0;
    switch br_try_be32(&r, 8) { ok(v) => { off_dt_struct = v; } err(e) => { return count; } }
    switch br_try_be32(&r, 12) { ok(v) => { off_dt_strings = v; } err(e) => { return count; } }

    var pos: usize = off_dt_struct as usize;
    var depth: u32 = 0;
    var node_counted: bool = false;

    var guard: usize = len / 4 + 1;
    while guard > 0 {
        guard = guard - 1;
        var tok: u32 = 0;
        switch br_try_be32(&r, pos) {
            ok(v) => { tok = v; }
            err(e) => { return count; }
        }
        pos = pos + 4;

        if tok == FDT_BEGIN_NODE {
            depth = depth + 1;
            switch fdt_skip_cstr(&r, pos) {
                ok(nxt) => { pos = fdt_align4(nxt); }
                err(e) => { return count; }
            }
            node_counted = false;
        } else if tok == FDT_END_NODE {
            if depth == 0 {
                return count;
            }
            depth = depth - 1;
            node_counted = false;
        } else if tok == FDT_PROP {
            var plen: u32 = 0;
            var nameoff: u32 = 0;
            switch br_try_be32(&r, pos) { ok(v) => { plen = v; } err(e) => { return count; } }
            switch br_try_be32(&r, pos + 4) { ok(v) => { nameoff = v; } err(e) => { return count; } }
            let val_off: usize = pos + 8;
            let soff: usize = (off_dt_strings as usize) + (nameoff as usize);

            if !node_counted {
                switch fdt_name_eq_compatible(&r, soff) {
                    ok(hit) => {
                        if hit {
                            switch fdt_compat_contains(&r, val_off, plen as usize, pat, plen_pat) {
                                ok(m) => {
                                    if m {
                                        count = count + 1;
                                        node_counted = true;
                                    }
                                }
                                err(e) => { return count; }
                            }
                        }
                    }
                    err(e) => { return count; }
                }
            }

            pos = fdt_align4(val_off + (plen as usize));
        } else if tok == FDT_NOP {
            // nothing
        } else if tok == FDT_END {
            return count;
        } else {
            return count;
        }
    }
    return count;
}

// ----- per-device exported wrappers (clean scalar ABI for the C boot runtime) -----

export fn fdt_find_uart(blob: PAddr, len: usize) -> FdtDevice {
    let pat: [16]u8 = fdt_pat_ns16550a();
    return fdt_find_compatible_impl(blob, len, pat, 8);
}
export fn fdt_find_plic(blob: PAddr, len: usize) -> FdtDevice {
    let pat: [16]u8 = fdt_pat_plic_riscv();
    return fdt_find_compatible_impl(blob, len, pat, 11);
}
export fn fdt_first_virtio_mmio(blob: PAddr, len: usize) -> FdtDevice {
    let pat: [16]u8 = fdt_pat_virtio_mmio();
    return fdt_find_compatible_impl(blob, len, pat, 11);
}
export fn fdt_count_virtio_mmio(blob: PAddr, len: usize) -> u32 {
    let pat: [16]u8 = fdt_pat_virtio_mmio();
    return fdt_count_compatible_impl(blob, len, pat, 11);
}

// ----- scalar PAddr entry points for the C device-discovery boot runtime -----
// (mirrors fdt_boot_*_pa: compute length from the header totalsize, return one
// scalar each so the C side stays free of MC struct layout.)

fn fdt_dev_total(blob: PAddr) -> usize {
    return fdt_totalsize(blob, 8) as usize;
}

export fn fdt_uart_base_pa(blob: PAddr) -> u64 {
    if !fdt_valid(blob, 8) { return 0; }
    let d: FdtDevice = fdt_find_uart(blob, fdt_dev_total(blob));
    return d.base;
}
export fn fdt_plic_base_pa(blob: PAddr) -> u64 {
    if !fdt_valid(blob, 8) { return 0; }
    let d: FdtDevice = fdt_find_plic(blob, fdt_dev_total(blob));
    return d.base;
}
export fn fdt_virtio_first_base_pa(blob: PAddr) -> u64 {
    if !fdt_valid(blob, 8) { return 0; }
    let d: FdtDevice = fdt_first_virtio_mmio(blob, fdt_dev_total(blob));
    return d.base;
}
export fn fdt_virtio_count_pa(blob: PAddr) -> u32 {
    if !fdt_valid(blob, 8) { return 0; }
    return fdt_count_virtio_mmio(blob, fdt_dev_total(blob));
}
