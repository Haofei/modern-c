// EXPECT: E_RESOURCE_LEAK — an Owned<T> from create() is never freed.
import "std/alloc.mc";
import "std/addr.mc";
import "kernel/core/heap.mc";
global g_pool: [4096]u8;
struct Cell { v: u32 }
fn bad() -> void {
    var heap: Heap = heap_new(phys_range(pa((&g_pool[0]) as usize), 4096));
    var a: Allocator = heap_allocator(&heap);
    var o: Owned<Cell> = create(Cell, &a);
}
