// kernel/fs/blobstore — a minimal durable blob sink.
//
// A place to write and read back self-describing checkpoint blobs (the prerequisite
// for checkpoint/restore). Blobs are opaque byte runs keyed by a `u32` id. A fixed
// directory of entries (id + offset + length + a present flag) indexes into a single
// backing byte arena that is bump-allocated; metadata is kept separate from the arena
// so no nested array-of-struct-of-array storage is needed. Every operation is
// bounds-checked and returns a typed error (no silent truncation, no wild copies):
// the directory filling up is `Full`, an absent id is `NotFound`, and a blob that
// will not fit in the remaining arena is `TooLarge`.
//
// Durability ("survives remount") is modelled honestly without a real block device:
// the directory and arena both live *in the struct*, so the bytes persist across a
// close/reopen cycle. A `blob_reopen` re-reads that same backing struct — it only
// resets transient state and re-derives the bump cursor from the live directory, so a
// blob written before a reopen is still readable after. The struct *is* the backing
// store; reopen is a view over it. (A real implementation would page this struct to a
// block device on close and read it back on open; the byte-for-byte invariant is the
// same one tested here.)

import "std/addr.mc";
import "std/mem.mc";

const MAX_BLOBS: usize = 8;     // directory capacity (entries)
const STORE_BYTES: usize = 4096; // backing arena size (bytes)

enum BlobError {
    Full,     // directory is full (no free entry for a new id)
    NotFound, // no present blob with that id
    TooLarge, // blob would not fit in the remaining arena
}

// One directory entry: where a blob's bytes live in the arena and how many there are.
// `present` distinguishes a live entry from an unused slot; an absent slot is never read.
struct BlobEntry {
    id: u32,
    off: usize,
    len: usize,
    present: bool,
}

struct BlobStore {
    dir: [MAX_BLOBS]BlobEntry, // fixed directory, indexed by slot (not by id)
    arena: [STORE_BYTES]u8,    // backing byte storage for all blobs
    bump: usize,               // next free arena offset (transient: re-derived on reopen)
}

// Find the directory slot holding a present blob with `id`, or MAX_BLOBS if none.
fn blob_find(s: *mut BlobStore, id: u32) -> usize {
    var i: usize = 0;
    while i < MAX_BLOBS {
        if s.dir[i].present {
            if s.dir[i].id == id {
                return i;
            }
        }
        i = i + 1;
    }
    return MAX_BLOBS;
}

// Reset the store to empty: clear every directory slot and rewind the bump cursor.
// The arena bytes are left as-is (a fresh blob overwrites only what it reserves).
export fn blob_init(s: *mut BlobStore) -> void {
    var i: usize = 0;
    while i < MAX_BLOBS {
        s.dir[i].present = false;
        i = i + 1;
    }
    s.bump = 0;
}

// Re-attach to an existing backing store after a close/reopen. The directory and arena
// bytes already persist in the struct, so the only work is re-deriving the transient
// bump cursor from the live directory (the high-water mark across present entries) —
// nothing is cleared, so blobs written before the reopen remain readable after it.
export fn blob_reopen(s: *mut BlobStore) -> void {
    var top: usize = 0;
    var i: usize = 0;
    while i < MAX_BLOBS {
        if s.dir[i].present {
            let end: usize = s.dir[i].off + s.dir[i].len;
            if end > top {
                top = end;
            }
        }
        i = i + 1;
    }
    s.bump = top;
}

// Store `len` bytes from `src` under `id`. A repeated id reuses its slot but appends
// fresh bytes (the directory then points at the new copy); a new id claims a free slot.
// Fails closed with `Full` if the directory is full or `TooLarge` if the bytes will not
// fit in the remaining arena — never a partial/truncated write.
export fn blob_put(s: *mut BlobStore, id: u32, src: PAddr, len: usize) -> Result<usize, BlobError> {
    if (s.bump + len) > STORE_BYTES {
        return err(.TooLarge);
    }
    var slot: usize = blob_find(s, id);
    if slot == MAX_BLOBS {
        // New id: claim the first free directory slot.
        var i: usize = 0;
        while i < MAX_BLOBS {
            if !s.dir[i].present {
                slot = i;
                break;
            }
            i = i + 1;
        }
        if slot == MAX_BLOBS {
            return err(.Full);
        }
    }
    let off: usize = s.bump;
    mem_copy(pa((&s.arena[off]) as usize), src, len); // single bounds-checked byte move
    s.bump = off + len;
    s.dir[slot].id = id;
    s.dir[slot].off = off;
    s.dir[slot].len = len;
    s.dir[slot].present = true;
    return ok(len);
}

// Length in bytes of the blob stored under `id`, or `NotFound`.
export fn blob_len(s: *mut BlobStore, id: u32) -> Result<usize, BlobError> {
    let slot: usize = blob_find(s, id);
    if slot == MAX_BLOBS {
        return err(.NotFound);
    }
    return ok(s.dir[slot].len);
}

// Copy the blob stored under `id` out to `dst`, up to `cap` bytes; returns the count
// copied (min of the blob length and `cap`). `NotFound` if no such blob is present.
export fn blob_get(s: *mut BlobStore, id: u32, dst: PAddr, cap: usize) -> Result<usize, BlobError> {
    let slot: usize = blob_find(s, id);
    if slot == MAX_BLOBS {
        return err(.NotFound);
    }
    var n: usize = s.dir[slot].len;
    if cap < n {
        n = cap; // honour the caller's buffer: copy at most `cap`, no overrun
    }
    mem_copy(dst, pa((&s.arena[s.dir[slot].off]) as usize), n);
    return ok(n);
}

// Number of present blobs in the directory.
export fn blob_count(s: *mut BlobStore) -> usize {
    var n: usize = 0;
    var i: usize = 0;
    while i < MAX_BLOBS {
        if s.dir[i].present {
            n = n + 1;
        }
        i = i + 1;
    }
    return n;
}
