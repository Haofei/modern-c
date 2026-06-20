// user/libc/syscall_user — the U-mode platform shim for a CONFINED agent: routes the libc's
// console output (sys_write, mc_console_write) through the SYS_WRITE ecall instead of touching
// hardware. The confined agent reaches the kernel ONLY through this syscall path.
//
// Deliberately imports NOTHING (no std/*), so it links as its own object alongside the
// aggregated libc without duplicating shared std helpers. `mc_ecall` is the single syscall
// primitive, provided by crt0 (the ELF entry runtime). SYS_WRITE = 0 (user/abi.mc).

const SYS_WRITE: u64 = 0;

extern fn mc_ecall(number: u64, a0: u64, a1: u64, a2: u64) -> u64;

// write(2): the C-ABI used by qjs_agent. fd in a0, buffer address in a1, length in a2.
export fn sys_write(fd: u64, buf: usize, len: usize) -> i64 {
    return bitcast<i64>(mc_ecall(SYS_WRITE, fd, buf as u64, len as u64));
}

// The stdio.mc console hook: always writes to fd 1 (stdout) via the same syscall.
export fn mc_console_write(buf: usize, len: usize) -> void {
    let ignored: u64 = mc_ecall(SYS_WRITE, 1, buf as u64, len as u64);
}
