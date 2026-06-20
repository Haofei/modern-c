// File syscalls wired to the VFS: open/write/read/close as ecall handlers. User
// pointers (the path and buffers) are validated + copied across the boundary with
// copy_{from,to}_user; the bytes then flow through the fd-table VFS over ramfs.

import "kernel/core/syscall.mc";
import "kernel/fs/vfs.mc";
import "kernel/core/uaccess.mc";
import "kernel/core/console.mc";
import "std/addr.mc";

const SYS_PUTC: usize = 2;
const SYS_OPEN: usize = 5;
const SYS_FWRITE: usize = 6;
const SYS_FREAD: usize = 7;
const SYS_FCLOSE: usize = 8;
const SYS_ERR: u64 = 0xFFFF_FFFF_FFFF_FFFF;

const USER_BASE: usize = 0x8000_0000;
const USER_LIMIT: usize = 0x9000_0000;
const NAME_MAX: usize = 32;
const IO_MAX: usize = 256;

global g_syscalls: SyscallTable;
global g_vfs: Vfs;
global g_namebuf: [NAME_MAX]u8;
global g_iobuf: [IO_MAX]u8;

// Forge a UserPtr<u8> from a user-supplied integer address: re-tagging an int into
// the UserPtr address class needs `unsafe` (kernel/core/uaccess.mc idiom). The audited
// copy_*_user boundary still validates the range.
fn uptr(a: usize) -> UserPtr<u8> {
    var p: UserPtr<u8> = uninit;
    unsafe { p = a as UserPtr<u8>; }
    return p;
}

fn sys_putc(ch: u64, a: u64, b: u64) -> u64 {
    console_putc(ch as u8);
    return 0;
}

// open(name_ptr, name_len) -> fd. Copies the user path into a kernel buffer first.
fn sys_open(name: u64, name_len: u64, a: u64) -> u64 {
    let n: usize = name_len as usize;
    if n > NAME_MAX {
        return SYS_ERR;
    }
    var us: UserSpace = user_space(USER_BASE, USER_LIMIT);
    let dst: PAddr = pa((&g_namebuf[0]) as usize);
    switch copy_from_user(&us, dst, uptr(name as usize), n) {
        ok(v) => {}
        err(e) => {
            return SYS_ERR;
        }
    }
    switch vfs_open(&g_vfs, (&g_namebuf[0]) as usize, n) {
        ok(fd) => {
            return fd as u64;
        }
        err(e) => {
            return SYS_ERR;
        }
    }
}

// write(fd, buf_ptr, len) -> bytes written.
fn sys_fwrite(fd: u64, buf: u64, len: u64) -> u64 {
    let n: usize = len as usize;
    if n > IO_MAX {
        return SYS_ERR;
    }
    var us: UserSpace = user_space(USER_BASE, USER_LIMIT);
    let dst: PAddr = pa((&g_iobuf[0]) as usize);
    switch copy_from_user(&us, dst, uptr(buf as usize), n) {
        ok(v) => {}
        err(e) => {
            return SYS_ERR;
        }
    }
    switch vfs_write(&g_vfs, fd as usize, (&g_iobuf[0]) as usize, n) {
        ok(written) => {
            return written as u64;
        }
        err(e) => {
            return SYS_ERR;
        }
    }
}

// read(fd, buf_ptr, len) -> bytes read (copied out to the user buffer).
fn sys_fread(fd: u64, buf: u64, len: u64) -> u64 {
    let n: usize = len as usize;
    if n > IO_MAX {
        return SYS_ERR;
    }
    var nread: usize = 0;
    switch vfs_read(&g_vfs, fd as usize, (&g_iobuf[0]) as usize, n) {
        ok(r) => {
            nread = r;
        }
        err(e) => {
            return SYS_ERR;
        }
    }
    var us: UserSpace = user_space(USER_BASE, USER_LIMIT);
    let src: PAddr = pa((&g_iobuf[0]) as usize);
    switch copy_to_user(&us, uptr(buf as usize), src, nread) {
        ok(v) => {}
        err(e) => {
            return SYS_ERR;
        }
    }
    return nread as u64;
}

fn sys_fclose(fd: u64, a: u64, b: u64) -> u64 {
    switch vfs_close(&g_vfs, fd as usize) {
        ok(ok_) => {
            return 0;
        }
        err(e) => {
            return SYS_ERR;
        }
    }
}

export fn syscall_setup() -> void {
    syscall_init(&g_syscalls);
    vfs_init(&g_vfs);
    syscall_register(&g_syscalls, SYS_PUTC, sys_putc);
    syscall_register(&g_syscalls, SYS_OPEN, sys_open);
    syscall_register(&g_syscalls, SYS_FWRITE, sys_fwrite);
    syscall_register(&g_syscalls, SYS_FREAD, sys_fread);
    syscall_register(&g_syscalls, SYS_FCLOSE, sys_fclose);
}

export fn mc_syscall(number: u64, arg0: u64, arg1: u64, arg2: u64) -> u64 {
    return syscall_dispatch(&g_syscalls, number, arg0, arg1, arg2);
}
