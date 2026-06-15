// kernel/fs/diskfs — a minimal *persistent* on-disk filesystem. Metadata (a superblock
// + an inode table) and file data live on the block device itself, accessed through
// bounds-checked byte views — so a fresh mount re-reads the layout from the device and
// sees previously written files (unlike the RAM-only ramfs). Flat namespace; each file
// gets one contiguous data block. This is the on-disk-format / inode gap, minimally.

import "std/bytes.mc";
import "std/mem.mc";
import "std/addr.mc";

const BLOCK: usize = 512;
const MAGIC: u32 = 0x4D434653; // "MCFS"
const MAX_FILES: usize = 8;
const SB_OFF: usize = 0;       // superblock @ block 0
const INODE_OFF: usize = 512;  // inode table @ block 1
const DATA_OFF: usize = 1024;  // data region @ block 2+
const INODE_SZ: usize = 8;     // per inode: size:u32 + data_offset:u32
const DIR_OFF: usize = 576;    // root directory (after the 64-byte inode table, same block)
const DIR_SZ: usize = 8;       // per entry: name_key:u32 + inode:u32

// Typed lookup error — NO sentinels: a caller can never confuse a real inode with a "missing".
enum DiskfsError {
    NotFound, // no directory entry matches the name
}

// Format the device: write the superblock magic + zero the inode table.
export fn diskfs_format(disk: PAddr, capacity: usize) -> void {
    var w: ByteWriter = byte_writer(disk, capacity);
    bw_be32(&w, SB_OFF + 0, MAGIC);
    bw_be32(&w, SB_OFF + 4, 0); // file count
    var i: usize = 0;
    while i < MAX_FILES {
        bw_be32(&w, INODE_OFF + i * INODE_SZ + 0, 0);
        i = i + 1;
    }
}

// A fresh mount: the device is a valid filesystem iff the magic is present.
export fn diskfs_mounted(disk: PAddr, capacity: usize) -> bool {
    var r: ByteReader = byte_reader(disk, capacity);
    return br_be32(&r, SB_OFF) == MAGIC;
}

// Allocate the next inode (one contiguous data block); returns its number.
export fn diskfs_create(disk: PAddr, capacity: usize) -> u32 {
    var w: ByteWriter = byte_writer(disk, capacity);
    var r: ByteReader = byte_reader(disk, capacity);
    let n: u32 = br_be32(&r, SB_OFF + 4);
    bw_be32(&w, INODE_OFF + (n as usize) * INODE_SZ + 0, 0); // size
    bw_be32(&w, INODE_OFF + (n as usize) * INODE_SZ + 4, (DATA_OFF + (n as usize) * BLOCK) as u32);
    bw_be32(&w, SB_OFF + 4, n + 1);
    return n;
}

// Create a file and link it into the root directory under `name_key`; returns its inode.
export fn diskfs_create_named(disk: PAddr, capacity: usize, name_key: u32) -> u32 {
    let ino: u32 = diskfs_create(disk, capacity);
    var w: ByteWriter = byte_writer(disk, capacity);
    bw_be32(&w, DIR_OFF + (ino as usize) * DIR_SZ + 0, name_key);
    bw_be32(&w, DIR_OFF + (ino as usize) * DIR_SZ + 4, ino);
    return ino;
}

// Resolve a name to its inode by scanning the root directory; NotFound if absent.
export fn diskfs_lookup(disk: PAddr, capacity: usize, name_key: u32) -> Result<u32, DiskfsError> {
    var r: ByteReader = byte_reader(disk, capacity);
    let n: u32 = br_be32(&r, SB_OFF + 4);
    var i: u32 = 0;
    while i < n {
        let k: u32 = br_be32(&r, DIR_OFF + (i as usize) * DIR_SZ + 0);
        if k == name_key {
            return ok(br_be32(&r, DIR_OFF + (i as usize) * DIR_SZ + 4));
        }
        i = i + 1;
    }
    return err(.NotFound);
}

// Write `len` bytes from `src` into file `ino`'s data block; record the size on disk.
export fn diskfs_write(disk: PAddr, capacity: usize, ino: u32, src: PAddr, len: usize) -> void {
    var w: ByteWriter = byte_writer(disk, capacity);
    var r: ByteReader = byte_reader(disk, capacity);
    let data_off: usize = br_be32(&r, INODE_OFF + (ino as usize) * INODE_SZ + 4) as usize;
    mem_copy(pa_offset(disk, data_off), src, len);
    bw_be32(&w, INODE_OFF + (ino as usize) * INODE_SZ + 0, len as u32);
}

// Read up to `max` bytes of file `ino` into `dst`; returns the byte count.
export fn diskfs_read(disk: PAddr, capacity: usize, ino: u32, dst: PAddr, max: usize) -> usize {
    var r: ByteReader = byte_reader(disk, capacity);
    let size: usize = br_be32(&r, INODE_OFF + (ino as usize) * INODE_SZ + 0) as usize;
    let data_off: usize = br_be32(&r, INODE_OFF + (ino as usize) * INODE_SZ + 4) as usize;
    var n: usize = size;
    if max < n {
        n = max;
    }
    mem_copy(dst, pa_offset(disk, data_off), n);
    return n;
}
