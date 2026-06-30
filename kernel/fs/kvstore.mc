// kernel/fs/kvstore — a small key/value store for agent context.
//
// Where blobstore is a fixed `u32 id -> bytes` checkpoint *sink* (write-mostly,
// no delete), this is a proper mutable map for agent memory: arbitrary `u64`
// keys to opaque byte values, with put/get/has/len/delete and in-place overwrite.
// A fixed directory of entries (key + offset + length + a present flag) indexes
// into a single backing byte arena; metadata is kept separate from the arena so
// no nested array-of-struct-of-array storage is needed. Every operation is
// bounds-checked and returns a typed error (no silent truncation, no wild copies):
// the directory filling up is `Full`, an absent key is `NotFound`, and a value
// that will not fit in the remaining arena is `TooLarge`.
//
// Storage strategy. Values are bump-allocated into the arena; the directory is
// indexed by slot (not by key), and a cleared `present` flag marks a free slot
// for reuse by a later `kv_put`. Deletion frees both the directory slot *and* the
// arena bytes: the hole left by a removed value is closed by compacting the live
// values above it down over the gap and fixing up their offsets, then the bump
// cursor is lowered by the freed length. This keeps the arena densely packed so
// the freed space is genuinely reusable (no fragmentation leak), at the cost of a
// linear move per delete — a deliberate trade for a small in-memory store. An
// overwrite that changes a value's size is modelled as delete-then-insert so the
// same compaction keeps the arena tight.

import "std/addr.mc";
import "std/mem.mc";

const MAX_KEYS: usize = 8;      // directory capacity (entries)
const KV_STORE_BYTES: usize = 4096; // backing arena size (bytes)

enum KvError {
    Full,     // directory is full (no free slot for a new key)
    NotFound, // no present value under that key
    TooLarge, // value would not fit in the remaining arena
}

// One directory entry: where a value's bytes live in the arena and how many there
// are. `present` distinguishes a live entry from a free slot; a free slot is never
// read and is the unit of reuse after a delete.
struct KvEntry {
    key: u64,
    off: usize,
    len: usize,
    present: bool,
}

struct KvStore {
    dir: [MAX_KEYS]KvEntry, // fixed directory, indexed by slot (not by key)
    arena: [KV_STORE_BYTES]u8, // backing byte storage for all values
    bump: usize,            // next free arena offset (top of the packed region)
}

// Find the directory slot holding a present value for `key`, or MAX_KEYS if none.
fn kv_find(s: *mut KvStore, key: u64) -> usize {
    var i: usize = 0;
    while i < MAX_KEYS {
        if s.dir[i].present {
            if s.dir[i].key == key {
                return i;
            }
        }
        i = i + 1;
    }
    return MAX_KEYS;
}

// Reset the store to empty: clear every directory slot and rewind the bump cursor.
// The arena bytes are left as-is (a fresh value overwrites only what it reserves).
export fn kv_init(s: *mut KvStore) -> void {
    var i: usize = 0;
    while i < MAX_KEYS {
        s.dir[i].present = false;
        i = i + 1;
    }
    s.bump = 0;
}

// Remove the value at directory `slot` (assumed present) and close its arena hole.
// Live values stored *above* the hole are slid down over it and their offsets fixed
// up; the bump cursor drops by the freed length. The slot's `present` flag is then
// cleared so a later `kv_put` can reuse it. Keeps the arena densely packed.
fn kv_evict(s: *mut KvStore, slot: usize) -> void {
    let hole_off: usize = s.dir[slot].off;
    let hole_len: usize = s.dir[slot].len;
    let tail: usize = hole_off + hole_len; // first byte after the hole
    let moved: usize = s.bump - tail;      // live bytes above the hole
    if moved > 0 {
        // Slide the packed region above the hole down by `hole_len` bytes. The
        // source and destination overlap (dst < src in the same arena), so this is
        // a memmove-style move that mem_copy forbids; a forward byte loop from the
        // low end is correct here because each destination byte is read before any
        // later iteration could overwrite it.
        var j: usize = 0;
        while j < moved {
            s.arena[hole_off + j] = s.arena[tail + j];
            j = j + 1;
        }
        // Fix up every present entry whose bytes lived above the hole.
        var i: usize = 0;
        while i < MAX_KEYS {
            if s.dir[i].present {
                if s.dir[i].off >= tail {
                    s.dir[i].off = s.dir[i].off - hole_len;
                }
            }
            i = i + 1;
        }
    }
    s.bump = s.bump - hole_len;
    s.dir[slot].present = false;
}

// Store `len` bytes from `src` under `key`, inserting a new key or OVERWRITING an
// existing one. An overwrite first evicts the old value (compacting the arena) so
// sizing is uniform with a fresh insert; the new value is then bump-allocated at the
// top of the packed region. Fails closed with `Full` if the directory has no free
// slot for a new key or `TooLarge` if the bytes will not fit in the remaining arena
// — never a partial/truncated write (capacity is checked before anything is moved).
export fn kv_put(s: *mut KvStore, key: u64, src: PAddr, len: usize) -> Result<usize, KvError> {
    var slot: usize = kv_find(s, key);
    if slot != MAX_KEYS {
        // Overwrite: the replacement reuses the old value's space, so check fit against the arena
        // AS IF the old value were already reclaimed (bump - old_len) — but check BEFORE evicting,
        // so a too-large replacement returns TooLarge with the existing value still intact (an
        // overwrite that fails must not destroy the old data). `s.bump >= old_len` always holds.
        let base_after_evict: usize = s.bump - s.dir[slot].len;
        if !fits_within(base_after_evict, len, KV_STORE_BYTES) {
            return err(.TooLarge); // old value preserved — nothing moved yet
        }
        kv_evict(s, slot);
    } else if !fits_within(s.bump, len, KV_STORE_BYTES) {
        return err(.TooLarge);
    }
    // Claim the first free directory slot (the evicted one is now free, if any).
    slot = MAX_KEYS;
    var i: usize = 0;
    while i < MAX_KEYS {
        if !s.dir[i].present {
            slot = i;
            break;
        }
        i = i + 1;
    }
    if slot == MAX_KEYS {
        return err(.Full);
    }
    let off: usize = s.bump;
    mem_copy(pa((&s.arena[off]) as usize), src, len); // single bounds-checked byte move
    s.bump = off + len;
    s.dir[slot].key = key;
    s.dir[slot].off = off;
    s.dir[slot].len = len;
    s.dir[slot].present = true;
    return ok(len);
}

// Length in bytes of the value stored under `key`, or `NotFound`.
export fn kv_len(s: *mut KvStore, key: u64) -> Result<usize, KvError> {
    let slot: usize = kv_find(s, key);
    if slot == MAX_KEYS {
        return err(.NotFound);
    }
    return ok(s.dir[slot].len);
}

// True if a value is present under `key`.
export fn kv_has(s: *mut KvStore, key: u64) -> bool {
    return kv_find(s, key) != MAX_KEYS;
}

// Copy the value stored under `key` out to `dst`, up to `cap` bytes; returns the
// count copied (min of the value length and `cap`). `NotFound` if no such value is
// present.
export fn kv_get(s: *mut KvStore, key: u64, dst: PAddr, cap: usize) -> Result<usize, KvError> {
    let slot: usize = kv_find(s, key);
    if slot == MAX_KEYS {
        return err(.NotFound);
    }
    var n: usize = s.dir[slot].len;
    if cap < n {
        n = cap; // honour the caller's buffer: copy at most `cap`, no overrun
    }
    mem_copy(dst, pa((&s.arena[s.dir[slot].off]) as usize), n);
    return ok(n);
}

// Delete the value under `key`, freeing its directory slot and arena bytes for
// reuse. Returns ok(true) if a value was removed, or `NotFound` if the key was
// absent (a typed miss rather than a silent no-op).
export fn kv_delete(s: *mut KvStore, key: u64) -> Result<bool, KvError> {
    let slot: usize = kv_find(s, key);
    if slot == MAX_KEYS {
        return err(.NotFound);
    }
    kv_evict(s, slot);
    return ok(true);
}

// Number of present values in the directory.
export fn kv_count(s: *mut KvStore) -> usize {
    var n: usize = 0;
    var i: usize = 0;
    while i < MAX_KEYS {
        if s.dir[i].present {
            n = n + 1;
        }
        i = i + 1;
    }
    return n;
}
