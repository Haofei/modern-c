// EXPECT: E_RESOURCE_LEAK — an Arc handle is never dropped (shared owner leaked).
import "std/collections/arc.mc";
import "std/alloc/alloc.mc";
import "std/addr.mc";
import "kernel/core/heap.mc";
struct Payload { value: u32 }
global g_pool: [4096]u8;
fn bad() -> void {
    var heap: Heap = heap_new(phys_range(pa((&g_pool[0]) as usize), 4096));
    let a: *mut dyn Allocator = heap_allocator(&heap);
    let p: Payload = .{ .value = 1 };
    var h: Arc<Payload> = arc_new(Payload, a, p);
}
