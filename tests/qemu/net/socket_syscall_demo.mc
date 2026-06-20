// recvfrom over the UDP socket layer, as a syscall. The kernel binds a socket and
// pre-delivers a datagram (standing in for the driver RX path); a U-mode program
// calls recvfrom, and the kernel copies the demultiplexed payload out to user space
// via the validated copy_to_user. Composes sockets + syscalls + user mode.

import "kernel/core/syscall.mc";
import "kernel/net/udp_socket.mc";
import "kernel/core/uaccess.mc";
import "kernel/core/console.mc";
import "std/addr.mc";

const SYS_PUTC: usize = 2;
const SYS_RECVFROM: usize = 9;
const SYS_ERR: u64 = 0xFFFF_FFFF_FFFF_FFFF;

const USER_BASE: usize = 0x8000_0000;
const USER_LIMIT: usize = 0x9000_0000;
const RXBUF: usize = 64;

global g_syscalls: SyscallTable;
global g_socks: SocketTable;
global g_rxbuf: [RXBUF]u8;

// Forge a UserPtr<u8> from a user-supplied integer address: re-tagging an int into
// the UserPtr address class needs `unsafe` (kernel/core/uaccess.mc idiom). The audited
// copy_to_user boundary still validates the range.
fn uptr(a: usize) -> UserPtr<u8> {
    var p: UserPtr<u8> = uninit;
    unsafe { p = a as UserPtr<u8>; }
    return p;
}

fn sys_putc(ch: u64, a: u64, b: u64) -> u64 {
    console_putc(ch as u8);
    return 0;
}

// recvfrom(sock, buf, len) -> bytes received (copied out to the user buffer).
fn sys_recvfrom(sock: u64, buf: u64, len: u64) -> u64 {
    let n_max: usize = len as usize;
    if n_max > RXBUF {
        return SYS_ERR;
    }
    var got: usize = 0;
    switch socket_recv(&g_socks, sock as usize, (&g_rxbuf[0]) as usize, n_max) {
        ok(n) => {
            got = n as usize;
        }
        err(e) => {
            return SYS_ERR;
        }
    }
    var us: UserSpace = user_space(USER_BASE, USER_LIMIT);
    let src: PAddr = pa((&g_rxbuf[0]) as usize);
    switch copy_to_user(&us, uptr(buf as usize), src, got) {
        ok(v) => {}
        err(e) => {
            return SYS_ERR;
        }
    }
    return got as u64;
}

export fn syscall_setup() -> void {
    syscall_init(&g_syscalls);
    socket_table_init(&g_socks);
    switch socket_bind(&g_socks, 0, 53) {
        ok(b) => {}
        err(e) => {}
    }
    // Deliver one datagram to port 53 (loopback for the driver RX path).
    var payload: [8]u8 = .{ 0x48, 0x45, 0x4C, 0x4C, 0x4F, 0, 0, 0 }; // "HELLO"
    switch socket_deliver(&g_socks, 53, 0x0A00_0202, 1234, (&payload[0]) as usize, 5) {
        ok(b) => {}
        err(e) => {}
    }
    syscall_register(&g_syscalls, SYS_PUTC, sys_putc);
    syscall_register(&g_syscalls, SYS_RECVFROM, sys_recvfrom);
}

export fn mc_syscall(number: u64, arg0: u64, arg1: u64, arg2: u64) -> u64 {
    return syscall_dispatch(&g_syscalls, number, arg0, arg1, arg2);
}
