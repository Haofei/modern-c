// Arc<T>: shared ownership. Two owners see the same value; dropping one doesn't free;
// dropping the last frees. (Leaking a handle is a compile error — kernel/bad/arc_leak.)

import "std/collections/arc.mc";
import "std/alloc/alloc.mc";
import "std/addr.mc";
import "kernel/core/heap.mc";

struct Payload { value: u32 }
global g_pool: [4096]u8;

fn payload_value(block: PAddr) -> u32 {
    let p: *const Payload = raw.ptr<Payload>(block);
    return p.value;
}

export fn arc_demo_run() -> u32 {
    var heap: Heap = uninit;
    heap_init(&heap, phys_range(pa((&g_pool[0]) as usize), 4096));
    let a: *mut dyn Allocator = heap_allocator(&heap);
    var pass: u32 = 1;

    let p: Payload = .{ .value = 0xBEEF };
    var h1: Arc<Payload> = arc_new(Payload, a, p);
    if arc_count(Payload, &h1) != 1 {
        pass = 0;
    }

    var h2: Arc<Payload> = arc_clone_from_parts(Payload, h1.block, h1.allocator); // second owner
    if arc_count(Payload, &h1) != 2 {
        pass = 0;
    }

    if payload_value(h1.block) != 0xBEEF {
        pass = 0;
    }
    if payload_value(h2.block) != 0xBEEF {
        pass = 0;
    }

    if arc_drop(Payload, h1) {
        pass = 0; // not the last owner -> must NOT free
    }
    if arc_count(Payload, &h2) != 1 {
        pass = 0; // h2 still valid; count back to 1
    }

    if !arc_drop(Payload, h2) {
        pass = 0; // last owner -> must free
    }

    return pass;
}
