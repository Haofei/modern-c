// EXPECT: E_USE_AFTER_MOVE — using a page after it was freed.
import "kernel/core/page_alloc.mc";
fn bad(a: *mut PageAllocator) -> PAddr {
    let p: Page = page_alloc(a);
    page_free(a, p);
    return page_addr(&p);
}
