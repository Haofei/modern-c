// kernel/fs/bcache — a write-back block cache over a device. Direct-mapped slots cache
// recently-used blocks; reads hit the cache when possible, writes update the cached copy
// and mark it dirty, and a flush (or eviction of a dirty slot) writes back to the device.
// The buffer cache the VFS/FS layers sit on, so file I/O isn't one device access per byte.

import "std/mem.mc";
import "std/addr.mc";

const BLOCK: usize = 512;
const NSLOTS: usize = 4;

struct BCache {
    dev: PAddr,
    dev_cap: usize,
    tag: [NSLOTS]u32,   // which block each slot holds
    valid: [NSLOTS]bool,
    dirty: [NSLOTS]bool,
    data: [2048]u8,     // NSLOTS * BLOCK bytes of cached block data
    hits: u32,
    misses: u32,
}

fn slot_of(blk: u32) -> usize {
    return (blk as usize) % NSLOTS;
}

fn slot_addr(c: *mut BCache, s: usize) -> PAddr {
    return pa((&c.data[s * BLOCK]) as usize);
}

fn dev_block(c: *mut BCache, blk: u32) -> PAddr {
    return pa_offset(c.dev, (blk as usize) * BLOCK);
}

export fn bcache_init(c: *mut BCache, dev: PAddr, cap: usize) -> void {
    c.dev = dev;
    c.dev_cap = cap;
    c.hits = 0;
    c.misses = 0;
    var i: usize = 0;
    while i < NSLOTS {
        c.valid[i] = false;
        c.dirty[i] = false;
        i = i + 1;
    }
}

fn writeback(c: *mut BCache, s: usize) -> void {
    let blk: u32 = c.tag[s];
    mem_copy(dev_block(c, blk), slot_addr(c, s), BLOCK);
    c.dirty[s] = false;
}

// Ensure block `blk` is resident in its slot, evicting (writing back) a dirty occupant.
fn ensure(c: *mut BCache, blk: u32) -> usize {
    let s: usize = slot_of(blk);
    if c.valid[s] {
        if c.tag[s] == blk {
            c.hits = c.hits + 1;
            return s;
        }
        if c.dirty[s] {
            writeback(c, s); // evict the old (dirty) block
        }
    }
    c.misses = c.misses + 1;
    mem_copy(slot_addr(c, s), dev_block(c, blk), BLOCK);
    c.tag[s] = blk;
    c.valid[s] = true;
    c.dirty[s] = false;
    return s;
}

export fn bcache_read(c: *mut BCache, blk: u32, dst: PAddr, n: usize) -> void {
    let s: usize = ensure(c, blk);
    mem_copy(dst, slot_addr(c, s), n);
}

export fn bcache_write(c: *mut BCache, blk: u32, src: PAddr, n: usize) -> void {
    let s: usize = ensure(c, blk);
    mem_copy(slot_addr(c, s), src, n);
    c.dirty[s] = true; // write-back: stays in cache until flush/evict
}

export fn bcache_flush(c: *mut BCache) -> void {
    var s: usize = 0;
    while s < NSLOTS {
        if c.valid[s] {
            if c.dirty[s] {
                writeback(c, s);
            }
        }
        s = s + 1;
    }
}

export fn bcache_hits(c: *BCache) -> u32 {
    return c.hits;
}
export fn bcache_misses(c: *BCache) -> u32 {
    return c.misses;
}
