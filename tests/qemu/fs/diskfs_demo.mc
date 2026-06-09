// On-disk FS persistence: format a device, create + write a file, then re-read it using
// only on-disk metadata (the "remount" path) — the bytes survive because the superblock,
// inode, and data all live on the device, not in RAM-only structures.

import "kernel/fs/diskfs.mc";
import "std/addr.mc";

global g_disk: [4096]u8; // the block device
global g_src: [8]u8;
global g_dst: [8]u8;

export fn diskfs_run() -> u32 {
    let disk: PAddr = pa((&g_disk[0]) as usize);
    let cap: usize = 4096;
    var pass: u32 = 1;

    diskfs_format(disk, cap);
    if !diskfs_mounted(disk, cap) {
        pass = 0;
    }
    let ino: u32 = diskfs_create_named(disk, cap, 0x666F6F); // create file "foo"

    g_src[0] = 0x50; g_src[1] = 0x45; g_src[2] = 0x52; g_src[3] = 0x53; // PERS
    g_src[4] = 0x49; g_src[5] = 0x53; g_src[6] = 0x54; g_src[7] = 0x21; // IST!
    diskfs_write(disk, cap, ino, pa((&g_src[0]) as usize), 8);

    // remount: re-read purely from the device, resolving the file by name
    if !diskfs_mounted(disk, cap) {
        pass = 0;
    }
    let found: u32 = diskfs_lookup(disk, cap, 0x666F6F); // resolve "foo" -> inode
    if found != ino {
        pass = 0;
    }
    let n: usize = diskfs_read(disk, cap, found, pa((&g_dst[0]) as usize), 8);
    if n != 8 {
        pass = 0;
    }
    var i: usize = 0;
    while i < 8 {
        if g_dst[i] != g_src[i] {
            pass = 0;
        }
        i = i + 1;
    }
    return pass;
}
