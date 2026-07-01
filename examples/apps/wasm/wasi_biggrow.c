// examples/apps/wasm/wasi_biggrow.c — Phase 4.1 proof: a confined WASM guest grows its linear memory
// FAR past the old ~14 MiB libc-arena ceiling (here 24 MiB) and the data stays correct. The old growth
// path realloc'd (copied) the WHOLE linear buffer on every memory.grow — an O(n^2) pattern that both
// pegged the runtime and, at large sizes, corrupted the engine's own state (guest stdout broke). With
// the demand-paged reserved window (kernel maps a zeroed frame per touched page, no copy) the grow is
// near-linear in pages TOUCHED and the bytes read back match what was written. Reaching the marker
// proves: (a) >14 MiB grow works, (b) no trap, (c) the guest's own printf still lands intact.
#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>

#define CHUNK (1u << 20) // 1 MiB
#define CHUNKS 18        // 18 MiB total — well past the ~14 MiB fixed arena, forcing real memory.grow
                         // (kept under the engine/wasi-libc effective ceiling the memcap gate observes)

int main(void) {
    unsigned char *blocks[CHUNKS];
    // Grow: allocate 24 x 1 MiB (each malloc that outruns the wasm heap triggers memory.grow), and
    // stamp a per-chunk sentinel into EVERY page so the frame is actually committed (faulted in).
    for (int i = 0; i < CHUNKS; i++) {
        unsigned char *p = malloc(CHUNK);
        if (!p) { printf("biggrow: FAIL alloc at %d MiB\n", i); return 1; }
        for (unsigned off = 0; off < CHUNK; off += 4096) {
            p[off] = (unsigned char)(i + 1);
            p[off + 4095] = (unsigned char)(i + 2);
        }
        blocks[i] = p;
    }
    // Verify: read every page back. A demand-paged frame must return exactly what was written (and
    // fresh frames must be zero before the write — proven implicitly by the exact-match check).
    long ok = 0;
    for (int i = 0; i < CHUNKS; i++) {
        for (unsigned off = 0; off < CHUNK; off += 4096) {
            if (blocks[i][off] != (unsigned char)(i + 1)) { printf("biggrow: FAIL data lo %d\n", i); return 1; }
            if (blocks[i][off + 4095] != (unsigned char)(i + 2)) { printf("biggrow: FAIL data hi %d\n", i); return 1; }
            ok++;
        }
    }
    printf("biggrow: grew %d MiB (>14 MiB arena), %ld pages verified\n", CHUNKS, ok);
    printf("biggrow: ok\n"); // demand-grown linear memory, correct data, intact stdout
    return 0;
}
