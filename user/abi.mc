// user/abi — the stable userspace syscall ABI (numbers), shared by the kernel (which
// registers handlers, kernel/arch/riscv64/app_runtime.c) and the user runtime (user/sys.mc,
// which issues the ecalls). Keep these numbers stable; appending is fine, renumbering is not.
//
// This is the SINGLE source of truth for syscall numbers: both the kernel (which registers
// handlers, casting to usize) and the user runtime (which issues the ecalls as u64) consume
// these — neither side hardcodes its own copy, so the ABI cannot drift.

export const SYS_WRITE: u64 = 0; // (fd, buf, len) -> bytes written (>=0) | -errno
export const SYS_READ: u64 = 1; // (buf, max) -> bytes delivered (>=0) | -errno  (§0 agent ingress)
export const SYS_GETPID: u64 = 2; // () -> pid
// SYS_EXIT is 3 to match the shared M-mode trap path (usermode_runtime.c handles a7==3
// specially: it returns control to the kernel rather than back to U-mode).
export const SYS_EXIT: u64 = 3; // (code) -> noreturn
// Async I/O (Phase 7): SYS_SUBMIT queues a non-blocking op and returns a request id (or
// -E_AGAIN when the kernel completion queue is full); SYS_POLL drains one completion ([id,
// result]) into a user buffer, returning 1 / 0 (empty) / -E_FAULT (bad user pointer).
export const SYS_SUBMIT: u64 = 4; // (op, arg) -> request id (>=0) | -E_AGAIN
export const SYS_POLL: u64 = 5; // (buf) -> 1 (delivered) | 0 (empty) | -E_FAULT

// Negative-errno results returned through the syscall ABI (Linux-compatible values).
export const E_AGAIN: i64 = -11; // EAGAIN: no capacity right now (back-pressure)
export const E_FAULT: i64 = -14; // EFAULT: a user pointer could not be accessed

// Standard descriptors (a minimal, fixed set for the console channel).
export const FD_STDOUT: u64 = 1;
