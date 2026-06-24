// Typed owned allocation: create<T> hands back a linear Owned<T> (leak-checked); we
// write/read through its address, then own_free consumes it.

import "std/alloc/alloc.mc";
import "std/addr.mc";
import "kernel/core/heap.mc";

global g_pool: [8192]u8;
struct Cell { v: u32 }

export fn owned_demo_run() -> u32 {
    let base: usize = (&g_pool[0]) as usize;
    var heap: Heap = heap_new(phys_range(pa(base), 8192));
    let a: *mut dyn Allocator = heap_allocator(&heap);
    var pass: u32 = 1;

    var o: Owned<Cell> = create(Cell, a);
    let addr: PAddr = own_addr(Cell, &o);
    unsafe {
        raw.store<u32>(addr, 0x1234);
    }
    let addr2: PAddr = own_addr(Cell, &o);
    unsafe {
        let v: u32 = raw.load<u32>(addr2);
        if v != 0x1234 {
            pass = 0;
        }
    }
    own_free(Cell, o); // consume the linear handle (else E_RESOURCE_LEAK)
    return pass;
}
