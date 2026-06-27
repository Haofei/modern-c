// examples/apps/wasm/wasi_shim.h — the U-mode WASI Preview 1 shim the wasm3 host links into a
// guest module. The shim translates WASI host calls into the kernel's narrow syscall ABI (Phase 1:
// fd_write/fd_read -> SYS_WRITE/SYS_READ; later phases route fs/net/clock through the brokers via
// SYS_SUBMIT/SYS_POLL). A WASI call is NOT a syscall — the trap boundary stays the six syscalls.
// See docs/wasm-migration-plan.md §2.

#ifndef MC_WASM_WASI_SHIM_H
#define MC_WASM_WASI_SHIM_H

#include "wasm3.h"

// Link every implemented WASI Preview 1 function into `module` under "wasi_snapshot_preview1".
// Imports the module does not declare are skipped (not an error), so one shim serves any guest.
M3Result wasm_wasi_link(IM3Module module);

// proc_exit unwinds the interpreter by returning this sentinel M3Result (identity-compared by the
// host) rather than a real trap; the exit code is stashed here.
extern const char *const wasm_wasi_proc_exit_result;
extern int wasm_wasi_exit_code;

#endif // MC_WASM_WASI_SHIM_H
