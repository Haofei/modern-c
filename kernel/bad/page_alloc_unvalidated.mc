// EXPECT: E_NO_IMPLICIT_CONVERSION — building an allocator from an unvalidated region.
import "kernel/core/page_alloc.mc";
fn bad() -> PageAllocator {
    return page_allocator_from(memory_map(0x8000_0000, 0x10000));
}
