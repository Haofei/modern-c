// Test wrappers around the VFS for the host driver: drive a global VFS and return
// scalars (fd / byte count / -1 on error) so the C side can assert without decoding
// the Result ABI.

import "kernel/fs/vfs.mc";

const VFS_ERR: u64 = 0xFFFF_FFFF_FFFF_FFFF;

global g_vfs: Vfs;

export fn v_init() -> void {
    vfs_init(&g_vfs);
}

export fn v_open(name: usize, name_len: usize) -> u64 {
    switch vfs_open(&g_vfs, name, name_len) {
        ok(fd) => {
            return fd as u64;
        }
        err(e) => {
            return VFS_ERR;
        }
    }
}

export fn v_write(fd: usize, src: usize, len: usize) -> u64 {
    switch vfs_write(&g_vfs, fd, src, len) {
        ok(n) => {
            return n as u64;
        }
        err(e) => {
            return VFS_ERR;
        }
    }
}

export fn v_read(fd: usize, dst: usize, len: usize) -> u64 {
    switch vfs_read(&g_vfs, fd, dst, len) {
        ok(n) => {
            return n as u64;
        }
        err(e) => {
            return VFS_ERR;
        }
    }
}

export fn v_close(fd: usize) -> u64 {
    switch vfs_close(&g_vfs, fd) {
        ok(b) => {
            return 0;
        }
        err(e) => {
            return VFS_ERR;
        }
    }
}
