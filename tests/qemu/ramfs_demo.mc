// Test wrappers around the ramfs for the host driver: drive a global filesystem
// and return scalars (handle / byte count / -1 on error) so the C side can assert
// without decoding the Result ABI.

import "kernel/fs/ramfs.mc";

const FS_ERR: u64 = 0xFFFF_FFFF_FFFF_FFFF;

global g_fs: Ramfs;

export fn fs_init() -> void {
    ramfs_init(&g_fs);
}

export fn fs_create(name: usize, name_len: usize, capacity: usize) -> u64 {
    switch ramfs_create(&g_fs, name, name_len, capacity) {
        ok(idx) => {
            return idx as u64;
        }
        err(e) => {
            return FS_ERR;
        }
    }
}

export fn fs_write(idx: usize, src: usize, len: usize) -> u64 {
    switch ramfs_write(&g_fs, idx, src, len) {
        ok(n) => {
            return n as u64;
        }
        err(e) => {
            return FS_ERR;
        }
    }
}

export fn fs_read(idx: usize, dst: usize, len: usize) -> u64 {
    return ramfs_read(&g_fs, idx, dst, len) as u64;
}

export fn fs_find(name: usize, name_len: usize) -> u64 {
    switch ramfs_find(&g_fs, name, name_len) {
        ok(idx) => {
            return idx as u64;
        }
        err(e) => {
            return FS_ERR;
        }
    }
}

export fn fs_size(idx: usize) -> u64 {
    return ramfs_size(&g_fs, idx) as u64;
}
