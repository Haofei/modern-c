// Freestanding "mc" platform port impl: memory from the all-MC libc heap, mmap from a static pool
// (the confined agent has a single flat address space), printf to libc, sync/thread/time as stubs.
#include "platform_api_vmcore.h"
#include "platform_api_extension.h"
#include <stdio.h>
#include <stdlib.h>

int bh_platform_init(void) { return 0; }
void bh_platform_destroy(void) {}

void *os_malloc(unsigned size) { return malloc(size); }
void *os_realloc(void *ptr, unsigned size) { return realloc(ptr, size); }
void os_free(void *ptr) { free(ptr); }

int os_printf(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt); int r = vprintf(fmt, ap); va_end(ap); return r;
}
int os_vprintf(const char *fmt, va_list ap) { return vprintf(fmt, ap); }

uint64 os_time_get_boot_us(void) { return 0; }
uint64 os_time_thread_cputime_us(void) { return 0; }

korp_tid os_self_thread(void) { return 0; }
uint8 *os_thread_get_stack_boundary(void) {
    // Single thread: return a conservative lower bound ~8 MiB below the current SP so WAMR's
    // native stack-overflow guard has a valid (non-NULL) boundary to compare against.
    uint8 probe;
    uintptr_t sp = (uintptr_t)&probe;
    uintptr_t margin = 8u * 1024u * 1024u;
    return (uint8 *)(sp > margin ? sp - margin : (uintptr_t)4096);
}
void os_thread_jit_write_protect_np(bool enabled) { (void)enabled; }

int os_mutex_init(korp_mutex *m) { (void)m; return 0; }
int os_mutex_destroy(korp_mutex *m) { (void)m; return 0; }
int os_mutex_lock(korp_mutex *m) { (void)m; return 0; }
int os_mutex_unlock(korp_mutex *m) { (void)m; return 0; }

// Single-threaded confined agent: condition variables are no-ops (nothing else runs to signal).
int os_cond_init(korp_cond *c) { (void)c; return 0; }
int os_cond_destroy(korp_cond *c) { (void)c; return 0; }
int os_cond_wait(korp_cond *c, korp_mutex *m) { (void)c; (void)m; return 0; }
int os_cond_reltimedwait(korp_cond *c, korp_mutex *m, uint64 useconds) { (void)c; (void)m; (void)useconds; return 0; }
int os_cond_signal(korp_cond *c) { (void)c; return 0; }
int os_cond_broadcast(korp_cond *c) { (void)c; return 0; }

// The confined agent has a single flat address space and uses the system allocator, so "mmap"
// regions (chiefly the wasm linear memory) come straight from the all-MC libc heap — NO large static
// pool (which would blow the confined load region alongside the libc arena). free reclaims them.
//
// Phase 4.1 (WASM linear-memory growth without the O(n) realloc-copy): when built with
// -DMC_WASM_LINEAR_RESERVE, the (single) wasm linear-memory reservation is instead handed a fixed VA
// WINDOW that the kernel DEMAND-PAGES (first access to a fresh page faults into M-mode, which maps one
// zeroed frame and retries). Growth (os_mremap) then costs NOTHING: we return the SAME window base and
// the new pages simply fault in on access — no realloc, no copy, no eager commit. The window/cap MUST
// match tests/qemu/proc/app_run_demo.mc's LM_WINDOW_BASE / LM_WINDOW_MAX (the kernel side that owns the
// backing pool and enforces confinement — only in-window faults are ever mapped). Without the macro the
// port keeps the malloc/realloc behaviour (linear memory capped at the libc arena, growth copies).
#ifdef MC_WASM_LINEAR_RESERVE
#define MC_LM_WINDOW_BASE ((uintptr_t)0x100000000ULL) /* == app_run_demo LM_WINDOW_BASE (4 GiB) */
#define MC_LM_WINDOW_MAX  ((size_t)0x03000000u)       /* == app_run_demo LM_WINDOW_MAX  (48 MiB) */
static int g_lm_reserved = 0; /* one active linear-memory reservation (single-module confined guest) */
#endif

void *os_mmap(void *hint, size_t size, int prot, int flags, os_file_handle file) {
    (void)hint; (void)prot; (void)flags; (void)file;
#ifdef MC_WASM_LINEAR_RESERVE
    // Route the (single) linear-memory reservation to the demand-paged kernel window. In this
    // freestanding interp build os_mmap is only ever called for linear memory (the HW-bound-check guard
    // page is compiled out), so a single reservation is sufficient; any further/oversized mmap falls
    // back to the heap so we never alias the window.
    if (!g_lm_reserved && size <= MC_LM_WINDOW_MAX) {
        g_lm_reserved = 1;
        return (void *)MC_LM_WINDOW_BASE;
    }
#endif
    return malloc(size);
}
void os_munmap(void *addr, size_t size) {
    (void)size;
#ifdef MC_WASM_LINEAR_RESERVE
    if ((uintptr_t)addr == MC_LM_WINDOW_BASE) { g_lm_reserved = 0; return; } /* window: nothing to free */
#endif
    free(addr);
}
int os_mprotect(void *addr, size_t size, int prot) { (void)addr; (void)size; (void)prot; return 0; }
void os_dcache_flush(void) {}
void os_icache_flush(void *start, size_t len) { (void)start; (void)len; }
void *os_mremap(void *old_addr, size_t old_size, size_t new_size) {
    (void)old_size;
#ifdef MC_WASM_LINEAR_RESERVE
    // Grow the demand-paged window IN PLACE: the VA is already reserved to the max, so enlarging is just
    // returning the same base — the extra pages fault in on first access. No copy (the O(n^2) killer is
    // gone). Past the window ceiling, fail with NULL so wasm memory.grow returns -1 GRACEFULLY.
    if ((uintptr_t)old_addr == MC_LM_WINDOW_BASE) {
        if (new_size > MC_LM_WINDOW_MAX) return NULL;
        return old_addr;
    }
#endif
    return realloc(old_addr, new_size);
}
int os_dumps_proc_mem_info(char *out, unsigned int size) { if (out && size) out[0] = 0; return 0; }
