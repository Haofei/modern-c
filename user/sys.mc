// user/sys — userspace syscall wrappers. A confined agent reaches the kernel ONLY through
// these; each issues a single `ecall` via the C shim `mc_ecall` (user/runtime/crt0.c), which
// loads the number into a7 and args into a0..a2 and traps to the kernel. This module imports
// NOTHING from the kernel — it is pure user code, linked into the app ELF.
//
// The kernel side copies any user buffer in/out through the agent's page table
// (copy_*_user_pt); the wrappers just pass the pointer as an integer.

import "user/abi.mc";

// The single ecall primitive (defined in C, where a0..a7 can be pinned — MC `asm precise`
// uses generic register constraints and cannot pin the syscall ABI registers).
extern fn mc_ecall(number: u64, a0: u64, a1: u64, a2: u64) -> u64;

// write(fd, buf, len): write `len` bytes from user buffer `buf` to `fd`. Returns the
// non-negative byte count, or a negative value (bitcast of -errno) on error.
export fn write(fd: u64, buf: usize, len: usize) -> i64 {
    return bitcast<i64>(mc_ecall(SYS_WRITE, fd, buf as u64, len as u64));
}

// Convenience: write a NUL-free byte buffer to stdout.
export fn print(buf: usize, len: usize) -> i64 {
    return write(FD_STDOUT, buf, len);
}

// getpid(): the agent's process id (its identity for capability attribution).
export fn getpid() -> u64 {
    return mc_ecall(SYS_GETPID, 0, 0, 0);
}

// read(buf, max): copy up to `max` bytes of the kernel-held agent source into `buf` (the §0
// ingress). Returns the byte count, or -E_FAULT (bitcast of negative) if `buf` is unwritable.
export fn read(buf: usize, max: usize) -> i64 {
    return bitcast<i64>(mc_ecall(SYS_READ, buf as u64, max as u64, 0));
}

// submit(req_ptr): start a non-blocking tool op described by a ToolReq at `req_ptr`; returns a
// request id (>=0), or -errno (E_FAULT/E_NOCAP/E_DENIED/E_AGAIN). poll(ev_ptr): fill a ToolEvent
// at `ev_ptr` for one ready completion; returns 1 (delivered), 0 (none), or -E_FAULT.
export fn submit(req_ptr: usize) -> i64 {
    return bitcast<i64>(mc_ecall(SYS_SUBMIT, req_ptr as u64, 0, 0));
}

// poll_many(events_ptr, max, timeout): drain up to `max` ready completions into a user array
// of ToolEvent[max] at `events_ptr`, advancing the broker's virtual clock up to `timeout` extra
// ticks while looking for ready completions. Returns the count delivered (0..max), or -E_FAULT.
export fn poll_many(events_ptr: usize, max: usize, timeout: usize) -> i64 {
    return bitcast<i64>(mc_ecall(SYS_POLL, events_ptr as u64, max as u64, timeout as u64));
}

// poll(ev_ptr): single-event back-compat form — fill ONE ToolEvent at `ev_ptr`. Returns 1
// (delivered), 0 (none ready), or -E_FAULT. Delegates to poll_many with max=1, timeout=0.
export fn poll(ev_ptr: usize) -> i64 {
    return poll_many(ev_ptr, 1, 0);
}

// sys_exit(code): terminate the agent. The kernel reclaims it and does not return; the
// returned `i64` is never actually observed (named `sys_exit`, not `exit`, to avoid clashing
// with the C library's `exit` builtin in the emitted C).
export fn sys_exit(code: u64) -> i64 {
    return bitcast<i64>(mc_ecall(SYS_EXIT, code, 0, 0));
}
