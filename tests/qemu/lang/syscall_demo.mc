// A syscall-skeleton demo: register a couple of syscalls in the dispatch table,
// then the runtime issues `ecall`s and the trap path routes them here by number.
// `mc_syscall` is the single entry the trap vector calls.

import "kernel/core/syscall.mc";
import "kernel/core/console.mc";
import "kernel/core/uaccess.mc";

const SYS_ADD: usize = 1;
const SYS_PUTC: usize = 2;
const SYS_WRITE: usize = 4;
const SYS_ERR: u64 = 0xFFFF_FFFF_FFFF_FFFF; // (u64)-1 returned on failure

// The user-accessible memory region (QEMU virt RAM). A pointer outside this range
// — e.g. a kernel address or a null-ish value — is rejected by copy_from_user.
const USER_BASE: usize = 0x8000_0000;
const USER_LIMIT: usize = 0x9000_0000;
const KBUF_SIZE: usize = 64;

global g_syscalls: SyscallTable;
global g_kbuf: [KBUF_SIZE]u8;

// sys_add(a, b) -> a + b
// Forge a UserPtr<u8> from a user-supplied integer address: re-tagging an int into
// the UserPtr address class needs `unsafe` (kernel/core/uaccess.mc idiom). The audited
// copy_from_user boundary still validates the range.
fn uptr(a: usize) -> UserPtr<u8> {
    var p: UserPtr<u8> = uninit;
    unsafe { p = a as UserPtr<u8>; }
    return p;
}

fn sys_add(a: u64, b: u64, c: u64) -> u64 {
    return a + b;
}

// sys_putc(ch, _) -> 0: write one byte to the console.
fn sys_putc(ch: u64, unused: u64, unused2: u64) -> u64 {
    console_putc(ch as u8);
    return 0;
}

// sys_write(ptr, len): validate + copy `len` bytes from the user buffer `ptr` into
// a kernel buffer, then write them to the console. Returns `len`, or -1 if the user
// range is rejected (out of bounds) or too large for the kernel buffer.
fn sys_write(ptr: u64, len: u64, unused: u64) -> u64 {
    let n: usize = len as usize;
    if n > KBUF_SIZE {
        return SYS_ERR;
    }
    let src: UserPtr<u8> = uptr(ptr as usize);
    let dst: PAddr = pa((&g_kbuf[0]) as usize);
    var us: UserSpace = user_space(USER_BASE, USER_LIMIT);
    switch copy_from_user(&us, dst, src, n) {
        ok(v) => {
            var i: usize = 0;
            while i < n {
                console_putc(g_kbuf[i]);
                i = i + 1;
            }
            return len;
        }
        err(e) => {
            return SYS_ERR;
        }
    }
}

// Register the kernel's syscalls + the user region. Called from bring-up before
// any ecall.
export fn syscall_setup() -> void {
    syscall_init(&g_syscalls);
    syscall_register(&g_syscalls, SYS_ADD, sys_add);
    syscall_register(&g_syscalls, SYS_PUTC, sys_putc);
    syscall_register(&g_syscalls, SYS_WRITE, sys_write);
}

// The trap vector calls this with the ecall's number (a7) and arguments (a0, a1);
// the result is written back to a0.
export fn mc_syscall(number: u64, arg0: u64, arg1: u64, arg2: u64) -> u64 {
    return syscall_dispatch(&g_syscalls, number, arg0, arg1, arg2);
}
