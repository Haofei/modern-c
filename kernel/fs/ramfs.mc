// kernel/fs/ramfs — a minimal in-memory filesystem.
//
// Files are flat byte streams keyed by name. Metadata (a fixed table of entries
// holding offsets + lengths) is kept separate from two flat pools — one for names,
// one for data — so no nested array-of-struct-of-array storage is needed. Every
// operation is bounds-checked and returns a typed error (no silent truncation, no
// wild copies); byte input is read through the bounds-checked std/bytes reader.

import "std/bytes.mc";
import "std/addr.mc";

const MAX_FILES: usize = 8;
const NAME_POOL: usize = 128;
const DATA_POOL: usize = 4096;

struct File {
    name_off: usize,
    name_len: usize,
    data_off: usize,
    capacity: usize,
    size: usize,
    used: bool,
}

struct Ramfs {
    files: [MAX_FILES]File,
    names: [NAME_POOL]u8,
    name_used: usize,
    data: [DATA_POOL]u8,
    data_used: usize,
}

enum FsError {
    NoSpace,     // file table full
    NameTooLong, // name pool exhausted
    NotFound,    // no file with that name
    TooLarge,    // write would exceed the file's data capacity
    BadIndex,    // file index out of range, or refers to an unused slot
    Exists,      // a file with that name already exists
}

// A file index is valid only if it is in range and names a live (used) slot. The raw API is
// public, so it validates every caller-supplied index rather than trusting the VFS layer —
// a stray index must fail closed, not read or corrupt a neighbouring file's metadata.
fn ramfs_valid(fs: *mut Ramfs, idx: usize) -> bool {
    if idx >= MAX_FILES {
        return false;
    }
    return fs.files[idx].used;
}

export fn ramfs_init(fs: *mut Ramfs) -> void {
    var i: usize = 0;
    while i < MAX_FILES {
        fs.files[i].used = false;
        i = i + 1;
    }
    fs.name_used = 0;
    fs.data_used = 0;
}

// Does file `idx` have the given name?
fn name_matches(fs: *mut Ramfs, idx: usize, q: *ByteReader, qlen: usize) -> bool {
    if fs.files[idx].name_len != qlen {
        return false;
    }
    let noff: usize = fs.files[idx].name_off;
    var j: usize = 0;
    while j < qlen {
        if fs.names[noff + j] != br_u8(q, j) {
            return false;
        }
        j = j + 1;
    }
    return true;
}

// Create a file with the given name. Rejects a duplicate name (so `find` stays unambiguous)
// and reserves a fixed slice of the data pool for the file's bytes. The raw API is public, so
// it enforces uniqueness itself rather than trusting the caller to `find` first.
export fn ramfs_create(fs: *mut Ramfs, name: usize, name_len: usize, capacity: usize) -> Result<usize, FsError> {
    var qr: ByteReader = byte_reader(pa(name), name_len);
    var k: usize = 0;
    while k < MAX_FILES {
        if fs.files[k].used {
            if name_matches(fs, k, &qr, name_len) {
                return err(.Exists);
            }
        }
        k = k + 1;
    }
    var slot: usize = MAX_FILES;
    var i: usize = 0;
    while i < MAX_FILES {
        if !fs.files[i].used {
            slot = i;
            break;
        }
        i = i + 1;
    }
    if slot == MAX_FILES {
        return err(.NoSpace);
    }
    if (fs.name_used + name_len) > NAME_POOL {
        return err(.NameTooLong);
    }
    if (fs.data_used + capacity) > DATA_POOL {
        return err(.TooLarge);
    }
    var nr: ByteReader = byte_reader(pa(name), name_len);
    let noff: usize = fs.name_used;
    var j: usize = 0;
    while j < name_len {
        fs.names[noff + j] = br_u8(&nr, j);
        j = j + 1;
    }
    fs.files[slot].name_off = noff;
    fs.files[slot].name_len = name_len;
    fs.files[slot].data_off = fs.data_used;
    fs.files[slot].capacity = capacity;
    fs.files[slot].size = 0;
    fs.files[slot].used = true;
    fs.name_used = noff + name_len;
    fs.data_used = fs.data_used + capacity;
    return ok(slot);
}

// Find a file by name.
export fn ramfs_find(fs: *mut Ramfs, name: usize, name_len: usize) -> Result<usize, FsError> {
    var q: ByteReader = byte_reader(pa(name), name_len);
    var i: usize = 0;
    while i < MAX_FILES {
        if fs.files[i].used {
            if name_matches(fs, i, &q, name_len) {
                return ok(i);
            }
        }
        i = i + 1;
    }
    return err(.NotFound);
}

// Append `len` bytes from `src` to file `idx`. The file's data lives in a fixed
// pool slice [data_off, data_off + capacity); appending past it is an error.
export fn ramfs_write(fs: *mut Ramfs, idx: usize, src: usize, len: usize) -> Result<usize, FsError> {
    if !ramfs_valid(fs, idx) {
        return err(.BadIndex);
    }
    return ramfs_write_at(fs, idx, fs.files[idx].size, src, len);
}

// Write `len` bytes from `src` to file `idx` starting at `offset`. The write may
// overwrite existing bytes or extend the file, but never past its reserved slice.
export fn ramfs_write_at(fs: *mut Ramfs, idx: usize, offset: usize, src: usize, len: usize) -> Result<usize, FsError> {
    if !ramfs_valid(fs, idx) {
        return err(.BadIndex);
    }
    let base: usize = fs.files[idx].data_off;
    let capacity: usize = fs.files[idx].capacity;
    if offset > capacity {
        return err(.TooLarge);
    }
    let room: usize = capacity - offset;
    if len > room {
        return err(.TooLarge);
    }
    var sr: ByteReader = byte_reader(pa(src), len);
    var j: usize = 0;
    while j < len {
        fs.data[base + offset + j] = br_u8(&sr, j);
        j = j + 1;
    }
    let end: usize = offset + len;
    if end > fs.files[idx].size {
        fs.files[idx].size = end;
    }
    return ok(len);
}

// Read up to `len` bytes of file `idx` starting at `offset` into `dst`. Returns the
// number copied (0 if `offset` is at/past end).
export fn ramfs_read_at(fs: *mut Ramfs, idx: usize, offset: usize, dst: usize, len: usize) -> usize {
    if !ramfs_valid(fs, idx) {
        return 0; // invalid/unused index: no bytes (a read returns a count, not a Result)
    }
    let base: usize = fs.files[idx].data_off;
    let size: usize = fs.files[idx].size;
    if offset >= size {
        return 0;
    }
    let avail: usize = size - offset;
    var n: usize = len;
    if avail < n {
        n = avail;
    }
    var j: usize = 0;
    while j < n {
        let b: u8 = fs.data[base + offset + j];
        unsafe {
            raw.store<u8>(phys(dst + j), b);
        }
        j = j + 1;
    }
    return n;
}

// Read from the start of file `idx`.
export fn ramfs_read(fs: *mut Ramfs, idx: usize, dst: usize, len: usize) -> usize {
    return ramfs_read_at(fs, idx, 0, dst, len);
}

export fn ramfs_size(fs: *mut Ramfs, idx: usize) -> usize {
    if !ramfs_valid(fs, idx) {
        return 0; // invalid/unused index reports empty rather than reading stale metadata
    }
    return fs.files[idx].size;
}

// Reserved capacity (max bytes) of a file, or 0 for an invalid index.
export fn ramfs_capacity(fs: *mut Ramfs, idx: usize) -> usize {
    if !ramfs_valid(fs, idx) {
        return 0;
    }
    return fs.files[idx].capacity;
}
