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
uint8 *os_thread_get_stack_boundary(void) { return NULL; }
void os_thread_jit_write_protect_np(bool enabled) { (void)enabled; }

int os_mutex_init(korp_mutex *m) { (void)m; return 0; }
int os_mutex_destroy(korp_mutex *m) { (void)m; return 0; }
int os_mutex_lock(korp_mutex *m) { (void)m; return 0; }
int os_mutex_unlock(korp_mutex *m) { (void)m; return 0; }

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
