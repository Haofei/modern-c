// examples/apps/sbrk_cap.c — Increment 2 proof: the demand-grown heap is BOUNDED by the per-agent
// ledger cap, and hitting the cap fails GRACEFULLY (malloc returns NULL, no trap, agent stays
// confined). The agent opts into growth, then malloc()s 1 MiB chunks in a bounded loop far past the
// cap. It must (a) grow well past the fixed static arena first (proving growth actually happened),
// then (b) get a clean NULL at the ledger ceiling — never a trap, never unbounded. Reaching the marker
// proves the kernel enforced the memory budget through the unified ledger (Resource.Memory).
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
#define LIMIT 200          // bounded loop; the cap (arena + grown ceiling) is far below this

int main(void) {
    mc_heap_grow_enable();

    static volatile unsigned char *chunks[LIMIT];
    int got = 0;
    for (int i = 0; i < LIMIT; i++) {
        volatile unsigned char *p = (volatile unsigned char *)malloc(CHUNK);
        if (!p) break;                       // clean stop at the ledger cap — NOT a trap
        p[0] = (unsigned char)(i + 1);       // commit one page of the demand-mapped frame
        p[CHUNK - PAGE] = (unsigned char)(i + 1);
        chunks[got++] = p;
    }

    // Bounded: the loop must have stopped at the cap, not run to LIMIT (that would mean no cap).
    if (got >= LIMIT) { emit("SBRK-CAP-FAIL: unbounded (no cap enforced)\n"); return 1; }
    // Growth actually happened: we allocated well past the ~14 MiB fixed static arena before capping.
    if (got <= 20) { emit("SBRK-CAP-FAIL: capped too early (no real growth)\n"); return 1; }

    // The frames handed out before the cap are real, distinct RAM (re-read each chunk's own tag).
    for (int i = 0; i < got; i++) {
        unsigned char tag = (unsigned char)(i + 1);
        if (chunks[i][0] != tag || chunks[i][CHUNK - PAGE] != tag) {
            emit("SBRK-CAP-FAIL: verify\n");
            return 1;
        }
    }

    emit("SBRK-CAP-OK\n");                    // grew past the arena, then capped gracefully at the ledger ceiling
    return 0;
}
