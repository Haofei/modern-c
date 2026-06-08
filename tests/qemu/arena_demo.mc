// Exercise the move Arena: bump-allocate, reset (batch reclaim + reuse), and destroy
// (consume the linear arena). Forgetting arena_destroy would be a compile error.

import "std/arena.mc";
import "std/addr.mc";

global g_pool: [8192]u8;

export fn arena_demo_run() -> u32 {
    let base: usize = (&g_pool[0]) as usize;
    var a: Arena = arena_init(phys_range(pa(base), 8192));

    let p1: usize = pa_value(arena_alloc(&a, 100, 16));
    let p2: usize = pa_value(arena_alloc(&a, 8, 32));
    var pass: u32 = 1;
    if p1 < base {
        pass = 0;
    }
    if (p1 % 16) != 0 {
        pass = 0;
    }
    if p2 < (p1 + 100) {
        pass = 0;
    }
    if (p2 % 32) != 0 {
        pass = 0;
    }

    arena_reset(&a); // reclaim everything
    let p3: usize = pa_value(arena_alloc(&a, 64, 16));
    if p3 != p1 {
        pass = 0; // reset rewinds the bump frontier — same address reused
    }

    arena_destroy(a); // consume the move Arena (else E_RESOURCE_LEAK)
    return pass;
}
