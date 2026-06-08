// kernel/core/posix — a POSIX-flavored syscall surface registered on the dispatch table:
// getpid + a file's open/write/read/close lifecycle (one in-memory file here). Shows the
// syscall ABI carrying real POSIX semantics, not just the ad-hoc demo calls.

import "kernel/core/syscall.mc";

const SYS_GETPID: usize = 10;
const SYS_OPEN: usize = 11;
const SYS_WRITE: usize = 12;
const SYS_READ: usize = 13;
const SYS_CLOSE: usize = 14;
const POSIX_EOF: u64 = 0x100;

global g_sys: SyscallTable;
global g_pid: u32;
global g_file: [64]u8;
global g_file_len: usize;
global g_pos: usize;

fn sys_getpid(a: u64, b: u64, c: u64) -> u64 {
    return g_pid as u64;
}
fn sys_open(a: u64, b: u64, c: u64) -> u64 {
    g_pos = 0;
    return 3; // a file descriptor
}
fn sys_write(fd: u64, byte: u64, c: u64) -> u64 {
    if g_file_len < 64 {
        g_file[g_file_len] = byte as u8;
        g_file_len = g_file_len + 1;
        return 1;
    }
    return 0;
}
fn sys_read(fd: u64, b: u64, c: u64) -> u64 {
    if g_pos < g_file_len {
        let v: u8 = g_file[g_pos];
        g_pos = g_pos + 1;
        return v as u64;
    }
    return POSIX_EOF;
}
fn sys_close(fd: u64, b: u64, c: u64) -> u64 {
    return 0;
}

export fn posix_setup(pid: u32) -> void {
    syscall_init(&g_sys);
    syscall_register(&g_sys, SYS_GETPID, sys_getpid);
    syscall_register(&g_sys, SYS_OPEN, sys_open);
    syscall_register(&g_sys, SYS_WRITE, sys_write);
    syscall_register(&g_sys, SYS_READ, sys_read);
    syscall_register(&g_sys, SYS_CLOSE, sys_close);
    g_pid = pid;
    g_file_len = 0;
    g_pos = 0;
}

export fn posix_call(number: u64, a0: u64, a1: u64, a2: u64) -> u64 {
    return syscall_dispatch(&g_sys, number, a0, a1, a2);
}
