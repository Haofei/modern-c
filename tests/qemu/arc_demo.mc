// Arc<T>: shared ownership. Two owners see the same value; dropping one doesn't free;
// dropping the last frees. (Leaking a handle is a compile error — kernel/bad/arc_leak.)

import "std/arc.mc";
import "std/alloc.mc";
import "std/addr.mc";
import "kernel/core/heap.mc";

struct Payload { value: u32 }
global g_pool: [4096]u8;

export fn arc_demo_run() -> u32 {
    var heap: Heap = heap_new(phys_range(pa((&g_pool[0]) as usize), 4096));
    var a: Allocator = heap_allocator(&heap);
    var pass: u32 = 1;

    let p: Payload = .{ .value = 0xBEEF };
    var h1: Arc<Payload> = arc_new(Payload, &a, p);
    if arc_count(Payload, &h1) != 1 {
        pass = 0;
    }

    var h2: Arc<Payload> = arc_clone(Payload, &h1); // second owner
    if arc_count(Payload, &h1) != 2 {
        pass = 0;
    }

    let v1: *mut Payload = arc_get(Payload, &h1);
    if v1.value != 0xBEEF {
        pass = 0;
    }
    let v2: *mut Payload = arc_get(Payload, &h2);
    if v2.value != 0xBEEF {
        pass = 0;
    }

    let freed1: bool = arc_drop(Payload, &a, h1); // consumes h1
    if freed1 {
        pass = 0; // not the last owner -> must NOT free
    }
    if arc_count(Payload, &h2) != 1 {
        pass = 0; // h2 still valid; count back to 1
    }

    let freed2: bool = arc_drop(Payload, &a, h2); // consumes h2
    if !freed2 {
        pass = 0; // last owner -> must free
    }

    return pass;
}
