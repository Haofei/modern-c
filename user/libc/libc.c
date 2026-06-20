// user/libc — a minimal freestanding libc for confined C apps (the surface QuickJS's core
// needs that the C compiler doesn't supply with -nostdlib -ffreestanding). Phase 2 of the
// QuickJS-agent plan. No syscalls here except via the app's heap arena; string/mem are pure.
//
// malloc/realloc/free: a bump allocator over a fixed static arena (in the app's .bss, so the
// loader maps + zeroes it). free is a no-op and realloc always copies — adequate for a v0
// agent; a real free-list allocator is a later refinement (plan Phase 5). The arena size
// bounds the agent's heap deterministically.
#include <stdint.h>
#include <stddef.h>

// ---- string / memory (pure) ----

void *memset(void *dst, int c, size_t n) {
    unsigned char *d = (unsigned char *)dst;
    for (size_t i = 0; i < n; i++) d[i] = (unsigned char)c;
    return dst;
}

void *memcpy(void *dst, const void *src, size_t n) {
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    for (size_t i = 0; i < n; i++) d[i] = s[i];
    return dst;
}

void *memmove(void *dst, const void *src, size_t n) {
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    if (d < s) {
        for (size_t i = 0; i < n; i++) d[i] = s[i];
    } else if (d > s) {
        for (size_t i = n; i != 0; i--) d[i - 1] = s[i - 1];
    }
    return dst;
}

int memcmp(const void *a, const void *b, size_t n) {
    const unsigned char *x = (const unsigned char *)a;
    const unsigned char *y = (const unsigned char *)b;
    for (size_t i = 0; i < n; i++) {
        if (x[i] != y[i]) return (int)x[i] - (int)y[i];
    }
    return 0;
}

size_t strlen(const char *s) {
    size_t n = 0;
    while (s[n]) n++;
    return n;
}

int strcmp(const char *a, const char *b) {
    while (*a && (*a == *b)) { a++; b++; }
    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

// ---- heap: bump allocator over a static arena ----

#ifndef MC_HEAP_ARENA_BYTES
#define MC_HEAP_ARENA_BYTES (256u << 10) // 256 KiB default (QuickJS overrides via -D)
#endif

static unsigned char g_arena[MC_HEAP_ARENA_BYTES] __attribute__((aligned(16)));
static size_t g_brk = 0;

static size_t align_up16(size_t n) { return (n + 15u) & ~((size_t)15u); }

void *malloc(size_t n) {
    if (n == 0) n = 1;
    size_t need = align_up16(n);
    if (need > MC_HEAP_ARENA_BYTES - g_brk) return (void *)0; // arena exhausted
    void *p = &g_arena[g_brk];
    g_brk += need;
    return p;
}

void *calloc(size_t count, size_t size) {
    size_t total = count * size;
    if (size != 0 && total / size != count) return (void *)0; // overflow
    void *p = malloc(total);
    if (p) memset(p, 0, total);
    return p;
}

void free(void *p) {
    (void)p; // bump allocator: no per-object reclaim (v0)
}

void *realloc(void *p, size_t n) {
    void *q = malloc(n);
    if (q && p) memcpy(q, p, n); // bump allocator can't know the old size; copy n (caller shrinks/grows)
    return q;
}
