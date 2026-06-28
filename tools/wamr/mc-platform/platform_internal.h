// Freestanding "mc" platform port for the confined U-mode WASM agent (no OS, no pthreads, no
// sockets) — built against the all-MC libc. Single-threaded: the korp_* sync types are dummies.
#ifndef _PLATFORM_INTERNAL_H
#define _PLATFORM_INTERNAL_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdarg.h>
#include <string.h>
#include <stdlib.h>
#include <limits.h>
#ifdef __cplusplus
extern "C" {
#endif
#ifndef BH_PLATFORM_MC
#define BH_PLATFORM_MC
#endif
// Single-threaded confined agent: synchronization primitives are no-ops.
typedef unsigned int korp_tid;
typedef unsigned int korp_mutex;
typedef unsigned int korp_cond;
typedef unsigned int korp_sem;
typedef unsigned int korp_thread;
typedef unsigned int korp_rwlock;
#define OS_THREAD_MUTEX_INITIALIZER 0
#define os_getpagesize() ((unsigned)4096)
#define bh_socket_t int
// File/socket handles are unused (WASI resolved by our native shim, LIBC_WASI=0): dummy handle type
// so the never-called file/socket os_* declarations parse.
typedef int os_file_handle;
typedef int os_raw_file_handle;
typedef void *os_dir_stream;
typedef int os_poll_file_handle;
typedef unsigned int os_nfds_t;
static inline os_file_handle os_get_invalid_handle(void) { return -1; }
int os_printf(const char *format, ...);
int os_vprintf(const char *format, va_list ap);
#ifdef __cplusplus
}
#endif
#endif
