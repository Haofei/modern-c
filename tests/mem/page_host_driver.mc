// Host-native driver for the physical frame allocator (kernel/core/page_alloc).
//
// The whole test lives in MC so NO MC struct (PageAllocator, Page, MemoryMap,
// PhysRange) is ever hand-mirrored in C — the silent by-value/sret ABI drift that
// bit the paging test cannot happen here. The C harness only supplies a backing
// pool and the trap stubs; it calls this one entry point, which returns 0 on
// success or a small nonzero id of the FIRST failed check.
//
// `Page` is a linear `move` resource: each page is bound to a `let`, its address
// is read via `page_addr(&p)` BEFORE it is consumed, and it is consumed exactly
// once by `page_free`. The linear discipline is total — a page must be consumed on
// EVERY function-exit path — so each failing-check path frees the pages still live
// at that point before returning its id. Addresses are compared through
// `pa_value(page_addr(&p))`.

import "kernel/core/page_alloc.mc";
import "std/addr.mc";

const PAGE: usize = 4096;

export fn page_host_test(pool_start: usize, pool_len: usize) -> u32 {
    var a: PageAllocator = page_allocator_from(validate(memory_map(pool_start, pool_len)));

    // 16 pages available initially.
    if pages_available(&a) != 16 {
        return 1;
    }

    // Bump allocation hands out consecutive frames: base, base+PAGE, base+2*PAGE.
    let p0: Page = page_alloc(&a);
    if pa_value(page_addr(&p0)) != pool_start {
        page_free(&a, p0);
        return 2;
    }
    let p1: Page = page_alloc(&a);
    if pa_value(page_addr(&p1)) != pool_start + PAGE {
        page_free(&a, p0);
        page_free(&a, p1);
        return 3;
    }
    let p2: Page = page_alloc(&a);
    if pa_value(page_addr(&p2)) != pool_start + 2 * PAGE {
        page_free(&a, p0);
        page_free(&a, p1);
        page_free(&a, p2);
        return 4;
    }

    // Available accounting after three allocations.
    if pages_available(&a) != 13 {
        page_free(&a, p0);
        page_free(&a, p1);
        page_free(&a, p2);
        return 5;
    }

    // Free returns the frame; available goes back up (real reclaim, not a leak).
    // This consumes p1; p0 and p2 stay live for the LIFO checks below.
    page_free(&a, p1);
    if pages_available(&a) != 14 {
        page_free(&a, p0);
        page_free(&a, p2);
        return 6;
    }

    // The next alloc reuses the just-freed frame (base + PAGE).
    let r: Page = page_alloc(&a);
    if pa_value(page_addr(&r)) != pool_start + PAGE {
        page_free(&a, p0);
        page_free(&a, p2);
        page_free(&a, r);
        return 7;
    }
    if pages_available(&a) != 13 {
        page_free(&a, p0);
        page_free(&a, p2);
        page_free(&a, r);
        return 8;
    }

    // LIFO free list: most-recently-freed frame is handed out first.
    page_free(&a, p0); // head -> p0
    page_free(&a, p2); // head -> p2
    let x: Page = page_alloc(&a);
    if pa_value(page_addr(&x)) != pool_start + 2 * PAGE { // p2 (last freed)
        page_free(&a, r);
        page_free(&a, x);
        return 9;
    }
    let y: Page = page_alloc(&a);
    if pa_value(page_addr(&y)) != pool_start { // p0
        page_free(&a, r);
        page_free(&a, x);
        page_free(&a, y);
        return 10;
    }
    if pages_available(&a) != 13 {
        page_free(&a, r);
        page_free(&a, x);
        page_free(&a, y);
        return 11;
    }

    // Success: consume the still-live handles so every Page is freed exactly once.
    page_free(&a, r);
    page_free(&a, x);
    page_free(&a, y);
    return 0;
}
