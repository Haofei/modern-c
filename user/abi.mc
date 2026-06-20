// user/abi — the stable userspace syscall ABI (numbers), shared by the kernel (which
// registers handlers, kernel/arch/riscv64/app_runtime.c) and the user runtime (user/sys.mc,
// which issues the ecalls). Keep these numbers stable; appending is fine, renumbering is not.
//
// Phase 1 surface (the minimum to run an app): write/exit/getpid. The compound tool/net and
// async calls (SYS_TOOL/SYS_NET/SYS_SUBMIT/SYS_POLL) land in later phases — see
// docs/quickjs-agent-plan.md §3.

export const SYS_WRITE: u64 = 0; // (fd, buf, len) -> bytes written (>=0) | -errno
export const SYS_GETPID: u64 = 2; // () -> pid
// SYS_EXIT is 3 to match the shared M-mode trap path (usermode_runtime.c handles a7==3
// specially: it returns control to the kernel rather than back to U-mode).
export const SYS_EXIT: u64 = 3; // (code) -> noreturn

// Standard descriptors (a minimal, fixed set for the console channel).
export const FD_STDOUT: u64 = 1;
