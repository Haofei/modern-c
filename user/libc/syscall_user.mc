// user/libc/syscall_user — the U-mode platform shim for a CONFINED agent: routes the libc's
// console output (sys_write, mc_console_write) through the SYS_WRITE ecall instead of touching
// hardware. The confined guest reaches the kernel ONLY through this syscall path.
//
// Imports ONLY user/abi.mc (which itself imports nothing — pure const definitions), so the
// syscall numbers come from the single ABI source of truth without pulling in std/* and
// duplicating shared helpers. `mc_ecall` is the single syscall primitive, provided by crt0
// (the ELF entry runtime).

import "user/abi.mc";
extern fn mc_ecall(number: u64, a0: u64, a1: u64, a2: u64) -> u64;

// Async tool I/O (Phase 7+): submit a non-blocking op described by a ToolReq at `req_ptr` (returns
// a request id >=0, or -errno). poll is the VECTOR drain: fill up to `max` ToolEvents at
// `events_ptr` (i-th event at offset i*sizeof(ToolEvent)) for ready completions, advancing the
// broker clock up to `timeout` extra ticks; returns the count delivered (0..max), or -E_FAULT.
// Confined C app fixtures may call this directly via `extern long sys_poll(...)`.
export fn sys_submit(req_ptr: usize) -> i64 {
    return bitcast<i64>(mc_ecall(SYS_SUBMIT, req_ptr as u64, 0, 0));
}

export fn sys_poll(events_ptr: usize, max: usize, timeout: usize) -> i64 {
    return bitcast<i64>(mc_ecall(SYS_POLL, events_ptr as u64, max as u64, timeout as u64));
}

// write(2): the C-ABI used by confined C apps. fd in a0, buffer address in a1, length in a2.
export fn sys_write(fd: u64, buf: usize, len: usize) -> i64 {
    return bitcast<i64>(mc_ecall(SYS_WRITE, fd, buf as u64, len as u64));
}

// The stdio.mc console hook: always writes to fd 1 (stdout) via the same syscall.
export fn mc_console_write(buf: usize, len: usize) -> void {
    let ignored: u64 = mc_ecall(SYS_WRITE, 1, buf as u64, len as u64);
}

// §0 ingress: read the agent source the kernel holds into `buf` (up to `max` bytes); returns the
// number of bytes delivered. The host calls this at boot instead of embedding the agent.
export fn sys_read(buf: usize, max: usize) -> i64 {
    return bitcast<i64>(mc_ecall(SYS_READ, buf as u64, max as u64, 0));
}

// Demand-grown heap: the libc allocator's break primitive. Grow the heap by `delta` bytes and return
// the OLD break VA, or a negative errno (as usize) on failure. This is the STRONG definition that
// overrides the weak "growth unavailable" default in user/libc/alloc.mc, so only a confined guest that
// links this shim (i.e. can ecall) actually gets a growable heap; plain host-side libc users keep the
// fixed arena. `delta == 0` queries the current break.
export fn __sbrk(delta: usize) -> usize {
    return mc_ecall(SYS_SBRK, delta as u64, 0, 0) as usize;
}
