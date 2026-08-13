// user/abi — the stable userspace syscall ABI (numbers), shared by the kernel (which
// registers handlers, kernel/arch/riscv64/app_runtime.c) and the user runtime (user/sys.mc,
// which issues the ecalls). Keep these numbers stable; appending is fine, renumbering is not.
//
// This is the SINGLE source of truth for syscall numbers: both the kernel (which registers
// handlers, casting to usize) and the user runtime (which issues the ecalls as u64) consume
// these — neither side hardcodes its own copy, so the ABI cannot drift.

export const SYS_WRITE: u64 = 0; // (fd, buf, len) -> bytes written (>=0) | -errno
export const SYS_READ: u64 = 1; // (buf, max) -> bytes delivered (>=0) | -errno
export const SYS_GETPID: u64 = 2; // () -> pid
// SYS_EXIT is 3 to match the shared M-mode trap path (usermode_runtime.c handles a7==3
// specially: it returns control to the kernel rather than back to U-mode).
export const SYS_EXIT: u64 = 3; // (code) -> noreturn
// Optional demand-grown guest heap. Classic sbrk: grow the guest break by `delta` bytes (rounded up to whole
// pages), mapping fresh R|W|U frames CONTIGUOUSLY at the running break VA, and return the OLD break VA
// (>=0). `delta == 0` queries the current break. On exhaustion / over-cap it returns a negative errno
// (-E_NOMEM) WITHOUT mapping anything, so a hostile or greedy guest gets NULL from malloc, never a trap.
export const SYS_SBRK: u64 = 4; // (delta) -> old break VA (>=0) | -E_NOMEM

// Negative-errno results returned through the syscall ABI (Linux-compatible values).
export const E_AGAIN: i64 = -11;     // EAGAIN: no capacity right now (back-pressure, retryable)
export const E_NOMEM: i64 = -12;     // ENOMEM: out of memory / over the per-guest grow cap (not retryable)
export const E_DENIED: i64 = -13;    // EACCES: policy denied this op (not retryable)
export const E_FAULT: i64 = -14;     // EFAULT: a user pointer could not be accessed

// Standard descriptors (a minimal, fixed set for the console channel).
export const FD_STDOUT: u64 = 1;
