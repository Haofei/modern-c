// Test wrappers for the block-backed file store, with a RAM-disk backend standing in
// for the virtio-blk driver (same BlockDevice vtable). `disk_byte` exposes the raw
// backing store so the test can confirm file data actually lands on the device.

import "kernel/fs/blockdev.mc";
import "std/addr.mc";

const DISK_BLOCKS: u64 = 8; // 8 * 512 = 4096 bytes

struct Disk { base: usize } // the RAM-disk backend's captured context

global g_disk: [4096]u8;
global g_disk_h: Disk;
global g_fs: BlockFs;

// The backend gets a *typed* `*Disk` (captured by the closure) — no ctx word, no cast.
fn ramdisk_read(d: *Disk, blk: u64, dst: usize) -> bool {
    let base: usize = d.base + (blk as usize) * 512;
    var i: usize = 0;
    while i < 512 {
        unsafe {
            let v: u8 = raw.load<u8>(phys(base + i));
            raw.store<u8>(phys(dst + i), v);
        }
        i = i + 1;
    }
    return true;
}
fn ramdisk_write(d: *Disk, blk: u64, src: usize) -> bool {
    let base: usize = d.base + (blk as usize) * 512;
    var i: usize = 0;
    while i < 512 {
        unsafe {
            let v: u8 = raw.load<u8>(phys(src + i));
            raw.store<u8>(phys(base + i), v);
        }
        i = i + 1;
    }
    return true;
}

const ERR: u64 = 0xFFFF_FFFF_FFFF_FFFF;

// Build the device handle on the stack each call. The read/write closures capture the
// RAM disk; virtio-blk would supply its own backend + captured context the same way.
fn make_dev() -> BlockDevice {
    g_disk_h.base = (&g_disk[0]) as usize;
    return .{
        .read = bind(&g_disk_h, ramdisk_read),
        .write = bind(&g_disk_h, ramdisk_write),
        .blocks = DISK_BLOCKS,
    };
}

export fn bfs_setup() -> void {
    bfs_init(&g_fs);
}

export fn bfs_create_(nblocks: u64) -> u64 {
    var dev: BlockDevice = make_dev();
    switch bfs_create(&g_fs, &dev, nblocks) {
        ok(i) => {
            return i as u64;
        }
        err(e) => {
            return ERR;
        }
    }
}
export fn bfs_write_(idx: usize, src: usize, len: usize) -> u64 {
    var dev: BlockDevice = make_dev();
    switch bfs_write(&g_fs, &dev, idx, src, len) {
        ok(n) => {
            return n as u64;
        }
        err(e) => {
            return ERR;
        }
    }
}
export fn bfs_read_(idx: usize, dst: usize, len: usize) -> u64 {
    var dev: BlockDevice = make_dev();
    switch bfs_read(&g_fs, &dev, idx, dst, len) {
        ok(n) => {
            return n as u64;
        }
        err(e) => {
            return ERR;
        }
    }
}
export fn bfs_size_(idx: usize) -> u64 {
    return bfs_size(&g_fs, idx) as u64;
}
// Raw backing-store byte (proves data is on the device, not a RAM pool).
export fn disk_byte(off: usize) -> u32 {
    return g_disk[off] as u32;
}
