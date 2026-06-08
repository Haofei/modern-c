// Test wrappers for the block-backed file store, with a RAM-disk backend standing in
// for the virtio-blk driver (same BlockDevice vtable). `disk_byte` exposes the raw
// backing store so the test can confirm file data actually lands on the device.

import "kernel/fs/blockdev.mc";
import "std/addr.mc";

const DISK_BLOCKS: u64 = 8; // 8 * 512 = 4096 bytes

global g_disk: [4096]u8;
global g_fs: BlockFs;

fn ramdisk_read(ctx: u64, blk: u64, dst: usize) -> bool {
    let base: usize = (ctx as usize) + (blk as usize) * 512;
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
fn ramdisk_write(ctx: u64, blk: u64, src: usize) -> bool {
    let base: usize = (ctx as usize) + (blk as usize) * 512;
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

// Build the device handle on the stack each call (a global struct-field store would
// emit a race-store intrinsic). The RAM-disk base is g_disk; virtio-blk would supply
// its own read/write + ctx the same way.
fn make_dev() -> BlockDevice {
    return .{
        .read = ramdisk_read,
        .write = ramdisk_write,
        .ctx = (&g_disk[0]) as u64,
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
