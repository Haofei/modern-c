// Generational handles: a handle resolves while live, but after arena_reset bumps the
// generation the same handle fails to resolve (StaleHandle) — runtime use-after-reset
// detection, fail closed, with no lifetimes in the language.

import "std/arena.mc";
import "std/addr.mc";

global g_pool: [4096]u8;
struct Cell { v: u32 }

export fn genref_demo_run() -> u32 {
    var a: Arena = arena_init(phys_range(pa((&g_pool[0]) as usize), 4096));
    var pass: u32 = 1;

    let h: GenRef<Cell> = arena_alloc_gen(Cell, &a, sizeof(Cell), alignof(Cell));

    // live: resolve + write, then resolve + read back
    switch arena_resolve(Cell, &a, h) {
        ok(addr) => {
            unsafe {
                raw.store<u32>(addr, 0xABCD);
            }
        }
        err(e) => {
            pass = 0;
        }
    }
    switch arena_resolve(Cell, &a, h) {
        ok(addr) => {
            unsafe {
                let v: u32 = raw.load<u32>(addr);
                if v != 0xABCD {
                    pass = 0;
                }
            }
        }
        err(e) => {
            pass = 0;
        }
    }

    // reset invalidates the handle's generation
    arena_reset(&a);
    switch arena_resolve(Cell, &a, h) {
        ok(addr) => {
            pass = 0; // BUG if reached: stale handle resolved
        }
        err(e) => {
            // expected: StaleHandle
        }
    }

    arena_destroy(a);
    return pass;
}
