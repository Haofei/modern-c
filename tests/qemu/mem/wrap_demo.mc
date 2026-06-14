// Long-running wrap / exhaustion test. Drives ring-buffer indices through many wrap-arounds
// and pool slot generations through many advances, asserting the invariants hold the whole
// way: a ring stays FIFO-correct across index wrap, a stale pool handle never revalidates even
// after the slot's generation has advanced far past it, and an exhausted pool fails closed
// (Full) at exactly its capacity. Complements the single-shot genref/pool/ring demos.

import "std/ring.mc";
import "std/pool.mc";

global g_ring: Ring<u32, 8>;
global g_pool: Pool<u32, 4>;

export fn wrap_run() -> u32 {
    // (1) Ring FIFO correctness across many head/tail index wrap-arounds.
    ring_init(u32, 8, &g_ring);
    var expect: u32 = 0; // next value we expect to pop
    var next: u32 = 0;   // next value to push
    var depth: u32 = 0;  // model of the ring's length
    var i: u32 = 0;
    while i < 200000 {
        if depth < 6 {
            if ring_push(u32, 8, &g_ring, next) {
                next = next + 1;
                depth = depth + 1;
            }
        }
        if depth > 0 {
            let got: u32 = ring_pop(u32, 8, &g_ring);
            if got != expect { return 0; } // FIFO order broke across a wrap
            expect = expect + 1;
            depth = depth - 1;
        }
        if (ring_len(u32, 8, &g_ring) as u32) != depth { return 0; } // length model diverged
        i = i + 1;
    }
    if next != expect { return 0; } // every value pushed was popped exactly once, in order

    // (2) A stale pool handle must never revalidate, even after the slot's generation has been
    // advanced many times by alloc/free reuse. Make a genuinely stale handle: alloc a slot and
    // free it, so the slot's generation has moved past the handle we keep.
    pool_init(u32, 4, &g_pool);
    var stale: PoolRef<u32> = uninit;
    switch pool_alloc(u32, 4, &g_pool) {
        ok(r) => {
            stale = r; // capture the handle (its generation is current)...
            switch pool_free(u32, 4, &g_pool, r) {
                ok(b) => {} // ...then free the slot, advancing its generation past `stale`
                err(e) => { return 0; }
            }
        }
        err(e) => { return 0; }
    }
    var cyc: u32 = 0;
    while cyc < 100000 {
        switch pool_alloc(u32, 4, &g_pool) {
            ok(r) => {
                switch pool_free(u32, 4, &g_pool, stale) {
                    ok(b) => { return 0; }   // stale handle revalidated -> fail
                    err(e) => {}             // StaleHandle expected
                }
                switch pool_free(u32, 4, &g_pool, r) {
                    ok(b) => {}
                    err(e) => { return 0; }  // a fresh handle must free cleanly
                }
            }
            err(e) => { return 0; }          // a single alloc on an empty pool is never Full
        }
        cyc = cyc + 1;
    }

    // (3) Exhaustion fails closed: exactly N allocations succeed, then Full.
    pool_init(u32, 4, &g_pool);
    var allocated: u32 = 0;
    var full_seen: bool = false;
    var k: u32 = 0;
    while k < 10 {
        switch pool_alloc(u32, 4, &g_pool) {
            ok(r) => { allocated = allocated + 1; } // leak the handle to exhaust the pool
            err(e) => { full_seen = true; }
        }
        k = k + 1;
    }
    if allocated != 4 { return 0; }
    if !full_seen { return 0; }

    return 1;
}
