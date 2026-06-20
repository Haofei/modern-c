// user/libc/syscall_user — the U-mode platform shim for a CONFINED agent: routes the libc's
// console output (sys_write, mc_console_write) through the SYS_WRITE ecall instead of touching
// hardware. The confined agent reaches the kernel ONLY through this syscall path.
//
// Deliberately imports NOTHING (no std/*), so it links as its own object alongside the
// aggregated libc without duplicating shared std helpers. `mc_ecall` is the single syscall
// primitive, provided by crt0 (the ELF entry runtime). SYS_WRITE = 0 (user/abi.mc).

const SYS_WRITE: u64 = 0;
const SYS_SUBMIT: u64 = 4;
const SYS_POLL: u64 = 5;

extern fn mc_ecall(number: u64, a0: u64, a1: u64, a2: u64) -> u64;

// Async I/O (Phase 7): submit a non-blocking op (returns a request id); poll drains one
// completion ([id, result]) into `buf` (returns 1 if delivered, 0 if none).
export fn sys_submit(arg: u64) -> i64 {
    return bitcast<i64>(mc_ecall(SYS_SUBMIT, 0, arg, 0));
}

export fn sys_poll(buf: usize) -> i64 {
    return bitcast<i64>(mc_ecall(SYS_POLL, buf as u64, 0, 0));
}

// write(2): the C-ABI used by qjs_agent. fd in a0, buffer address in a1, length in a2.
export fn sys_write(fd: u64, buf: usize, len: usize) -> i64 {
    return bitcast<i64>(mc_ecall(SYS_WRITE, fd, buf as u64, len as u64));
}

// The stdio.mc console hook: always writes to fd 1 (stdout) via the same syscall.
export fn mc_console_write(buf: usize, len: usize) -> void {
    let ignored: u64 = mc_ecall(SYS_WRITE, 1, buf as u64, len as u64);
}
