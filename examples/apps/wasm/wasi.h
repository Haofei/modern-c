// examples/apps/wasm/wasi.h — the WASI Preview 1 ABI surface the shim implements, defined
// freestanding (the upstream m3_api_wasi.h pulls in POSIX). Only what Phase 1 needs:
// the errno/filetype/clockid enums, the fdstat struct layout, and the translation from the
// kernel's Linux-style negative errno (user/abi.mc) to WASI's own __wasi_errno_t.
//
// docs/wasm-migration-plan.md Phase 1: "The shim must map kernel results to WASI errno ...
// Centralize this in one table in the shim so every WASI call returns conformant codes."

#ifndef MC_WASM_WASI_H
#define MC_WASM_WASI_H

#include <stdint.h>

// __wasi_errno_t (witx canonical values — NOT the Linux numbers in user/abi.mc).
#define WASI_ESUCCESS      0
#define WASI_E2BIG         1
#define WASI_EACCES        2
#define WASI_EAGAIN        6
#define WASI_EBADF         8
#define WASI_EFAULT        21
#define WASI_EINVAL        28
#define WASI_EIO           29
#define WASI_ENOENT        44
#define WASI_ENOMEM        48
#define WASI_ENOBUFS       42
#define WASI_ENOSYS        52
#define WASI_ENOTSUP       58
#define WASI_ESPIPE        70
#define WASI_ETIMEDOUT     73
#define WASI_ECANCELED     11
#define WASI_EPERM         63
#define WASI_ENOTCAPABLE   76

// __wasi_filetype_t.
#define WASI_FILETYPE_UNKNOWN          0
#define WASI_FILETYPE_BLOCK_DEVICE     1
#define WASI_FILETYPE_CHARACTER_DEVICE 2
#define WASI_FILETYPE_DIRECTORY        3
#define WASI_FILETYPE_REGULAR_FILE     4
#define WASI_FILETYPE_SOCKET_DGRAM     5
#define WASI_FILETYPE_SOCKET_STREAM    6
#define WASI_FILETYPE_SYMBOLIC_LINK    7

// __wasi_clockid_t.
#define WASI_CLOCK_REALTIME            0
#define WASI_CLOCK_MONOTONIC           1
#define WASI_CLOCK_PROCESS_CPUTIME_ID  2
#define WASI_CLOCK_THREAD_CPUTIME_ID   3

// __wasi_fdstat_t — 24 bytes, the layout fd_fdstat_get writes into guest memory.
typedef struct {
    uint8_t  fs_filetype;        // +0
    uint8_t  _pad0;
    uint16_t fs_flags;           // +2
    uint8_t  _pad1[4];
    uint64_t fs_rights_base;     // +8
    uint64_t fs_rights_inheriting; // +16
} wasi_fdstat_t;                 // sizeof == 24

// The kernel ABI (user/abi.mc) returns Linux-style negative errno. Map those to WASI errno so
// every shim function returns a conformant __wasi_errno_t. Centralized per the plan.
//   E_AGAIN=-11 E_DENIED=-13 E_FAULT=-14 E_NOCAP=-105 E_TIMEDOUT=-110 E_CANCELED=-125
static inline uint32_t wasi_errno_from_kernel(long r) {
    switch (r) {
        case 0:    return WASI_ESUCCESS;
        case -11:  return WASI_EAGAIN;      // E_AGAIN  (back-pressure, retryable)
        case -13:  return WASI_EACCES;      // E_DENIED (policy denied)
        case -14:  return WASI_EFAULT;      // E_FAULT  (bad user pointer)
        case -105: return WASI_ENOBUFS;     // E_NOCAP  (exceeds a hard capacity bound)
        case -110: return WASI_ETIMEDOUT;   // E_TIMEDOUT
        case -125: return WASI_ECANCELED;   // E_CANCELED
        default:   return (r < 0) ? WASI_EIO : WASI_ESUCCESS;
    }
}

#endif // MC_WASM_WASI_H
