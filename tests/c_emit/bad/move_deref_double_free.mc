// EXPECT: E_USE_AFTER_MOVE
// Moving a linear `move` value through a full deref alias consumes the owning binding `o`.
// The trailing `own_free(Cell, o)` must then be rejected as use-after-move, preventing a
// double free of the same allocation.
import "std/alloc/alloc.mc";
import "std/addr.mc";
import "kernel/core/heap.mc";
global g_pool: [4096]u8;
struct Cell { v: u32 }
fn bad() -> void {
    var heap: Heap = heap_new(phys_range(pa((&g_pool[0]) as usize), 4096));
    let a: *mut dyn Allocator = heap_allocator(&heap);
    var o: Owned<Cell> = create(Cell, a);
    var p: *mut Owned<Cell> = &o;
    own_free(Cell, *p);
    own_free(Cell, o);
}
