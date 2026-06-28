// examples/apps/wasm/wasi_memcap.c — Phase-5 linear-memory cap: prove the confined WASM guest's heap
// is BOUNDED and that hitting the bound fails GRACEFULLY (no trap, no kernel impact, agent stays
// confined). The guest allocates 1 MiB chunks until the wasm linear memory (grown from the agent's
// libc arena) is exhausted; at the cap, wasm `memory.grow` returns -1, wasi-libc's allocator returns
// NULL, and the loop stops cleanly. Reaching the marker proves the engine enforced the memory budget
// without faulting — the security property: an untrusted agent cannot exhaust host memory, and an
// out-of-memory condition is a normal, confined error rather than a crash.
#include <stdlib.h>
#include <stdio.h>

int main(void) {
    int chunks = 0;
    for (;;) {
        void *p = malloc(1u << 20);          // 1 MiB
        if (!p) break;                       // controlled failure at the linear-memory cap
        ((volatile char *)p)[0] = 1;         // touch one byte so the page is committed
        if (++chunks > 8192) break;          // safety: never loop unbounded
    }
    if (chunks <= 0) { printf("memcap: FAIL no-alloc\n"); return 1; }
    if (chunks > 8192) { printf("memcap: FAIL unbounded (no cap enforced)\n"); return 1; }
    printf("memcap: capped after %d MiB\n", chunks);
    printf("memcap: ok\n");                  // graceful: malloc returned NULL, no trap, agent confined
    return 0;
}
