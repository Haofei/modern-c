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

// Linear memory + module data come from a static pool (single flat address space, no real mmap).
#define MC_MMAP_POOL_BYTES (24u * 1024u * 1024u)
static unsigned char g_mmap_pool[MC_MMAP_POOL_BYTES];
static size_t g_mmap_off = 0;
void *os_mmap(void *hint, size_t size, int prot, int flags, os_file_handle file) {
    (void)hint; (void)prot; (void)flags; (void)file;
    size = (size + 4095u) & ~((size_t)4095u);
    if (g_mmap_off + size > MC_MMAP_POOL_BYTES) return NULL;
    void *p = &g_mmap_pool[g_mmap_off]; g_mmap_off += size; return p;
}
void os_munmap(void *addr, size_t size) { (void)addr; (void)size; } // bump pool: no reclaim
int os_mprotect(void *addr, size_t size, int prot) { (void)addr; (void)size; (void)prot; return 0; }
void os_dcache_flush(void) {}
void os_icache_flush(void *start, size_t len) { (void)start; (void)len; }
void *os_mremap(void *old_addr, size_t old_size, size_t new_size) {
    void *p = os_mmap(NULL, new_size, MMAP_PROT_READ | MMAP_PROT_WRITE, 0, os_get_invalid_handle());
    if (p && old_addr) { size_t n = old_size < new_size ? old_size : new_size; memcpy(p, old_addr, n); }
    return p;
}
int os_dumps_proc_mem_info(char *out, unsigned int size) { if (out && size) out[0] = 0; return 0; }
