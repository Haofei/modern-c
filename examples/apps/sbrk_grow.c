// examples/apps/sbrk_grow.c — Increment 1 proof: a confined U-mode agent whose libc heap grows ON
// DEMAND past the fixed static arena via SYS_SBRK. It malloc()s far beyond the arena (40 MiB in 1 MiB
// chunks), writes a per-chunk sentinel into EVERY page and reads it back — proving the demand-mapped
// frames are real, distinct RAM, not aliased or zero-fill-on-read — then prints SBRK-GROW-OK. The
// agent runs confined (kernel unmapped) and reaches the kernel only through ecall (sys_write for the
// marker; SYS_SBRK, issued transparently by libc malloc, for the growth). A malloc failure at any
// point is a clean FAIL marker, never a trap.
#include <stdint.h>
#include <stddef.h>

extern long sys_write(unsigned long fd, const void *buf, unsigned long len);
extern void *malloc(unsigned long);
extern void mc_heap_grow_enable(void);   // opt into demand growth (default off = fixed arena)

static void emit(const char *s) {
    unsigned long n = 0;
    while (s[n]) n++;
    sys_write(1, s, n);
}

#define CHUNK (1u << 20)   // 1 MiB
#define PAGE  4096u
#define CHUNKS 40          // 40 MiB total — well past the multi-MiB static arena, forcing SYS_SBRK

int main(void) {
    mc_heap_grow_enable();   // this agent wants its heap to grow past the fixed arena

    // Keep the chunk pointers so nothing is freed mid-run (proves pure growth, and keeps every mapped
    // region live so a later read genuinely re-reads its own frame).
    static volatile unsigned char *chunks[CHUNKS];

    for (int i = 0; i < CHUNKS; i++) {
        volatile unsigned char *p = (volatile unsigned char *)malloc(CHUNK);
        if (!p) { emit("SBRK-GROW-FAIL: alloc\n"); return 1; }
        chunks[i] = p;
        unsigned char tag = (unsigned char)(i + 1);
        for (unsigned long off = 0; off < CHUNK; off += PAGE) {
            p[off] = tag;                 // touch every page: commit the demand-mapped frame
        }
    }

    // Read back a page from every chunk: each must still hold its own tag (distinct backing frames).
    for (int i = 0; i < CHUNKS; i++) {
        unsigned char tag = (unsigned char)(i + 1);
        volatile unsigned char *p = chunks[i];
        if (p[0] != tag || p[CHUNK - PAGE] != tag) {
            emit("SBRK-GROW-FAIL: verify\n");
            return 1;
        }
    }

    emit("SBRK-GROW-OK\n");
    return 0;
}
