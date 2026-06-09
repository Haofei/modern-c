// A U-mode server: a service that runs in *user mode* (privilege-isolated), reaching
// the kernel only through ecalls. It loops pulling requests (SYS_RECV), computes a
// reply (double), and hands each back (SYS_REPLY); when drained it asks the kernel to
// verify (SYS_VERIFY). The server cannot touch kernel memory directly — every effect
// goes through the syscall gate. This is the MINIX model: servers are user processes.

import "kernel/core/syscall.mc";
import "kernel/core/console.mc";

const SYS_RECV: usize = 5;
const SYS_REPLY: usize = 6;
const SYS_VERIFY: usize = 7;
const DONE: u64 = 0xFFFF_FFFF_FFFF_FFFF;

global g_syscalls: SyscallTable;
global g_requests: [4]u64;
global g_req_count: usize;
global g_req_next: usize;
global g_replies: [4]u64;
global g_reply_count: usize;

fn sys_recv(a: u64, b: u64, c: u64) -> u64 {
    if g_req_next >= g_req_count {
        return DONE;
    }
    let v: u64 = g_requests[g_req_next];
    g_req_next = g_req_next + 1;
    return v;
}

fn sys_reply(result: u64, b: u64, c: u64) -> u64 {
    if g_reply_count < 4 {
        g_replies[g_reply_count] = result;
        g_reply_count = g_reply_count + 1;
    }
    return 0;
}

fn sys_verify(a: u64, b: u64, c: u64) -> u64 {
    var pass: bool = true;
    if g_reply_count != 3 {
        pass = false;
    }
    if g_replies[0] != 20 {
        pass = false;
    }
    if g_replies[1] != 40 {
        pass = false;
    }
    if g_replies[2] != 60 {
        pass = false;
    }
    // "USERVER-" then OK/BAD
    console_putc(0x55); console_putc(0x53); console_putc(0x45); console_putc(0x52);
    console_putc(0x56); console_putc(0x45); console_putc(0x52); console_putc(0x2D);
    if pass {
        console_putc(0x4F); console_putc(0x4B); // OK
    } else {
        console_putc(0x42); console_putc(0x41); console_putc(0x44); // BAD
    }
    console_putc(0x0A);
    return 0;
}

export fn syscall_setup() -> void {
    syscall_init(&g_syscalls);
    syscall_register(&g_syscalls, SYS_RECV, sys_recv);
    syscall_register(&g_syscalls, SYS_REPLY, sys_reply);
    syscall_register(&g_syscalls, SYS_VERIFY, sys_verify);
    g_req_count = 3;
    g_req_next = 0;
    g_reply_count = 0;
    g_requests[0] = 10;
    g_requests[1] = 20;
    g_requests[2] = 30;
}

export fn mc_syscall(number: u64, arg0: u64, arg1: u64, arg2: u64) -> u64 {
    return syscall_dispatch(&g_syscalls, number, arg0, arg1, arg2);
}
