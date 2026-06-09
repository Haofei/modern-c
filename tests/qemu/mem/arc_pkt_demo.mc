// Step 4: a shared network buffer. A received packet is Arc-shared between two
// consumers (e.g. the protocol layer and a logger). Each reads the same bytes through
// its own owner and releases it; the buffer is freed exactly when the last owner drops
// — the skb/mbuf refcount pattern, with handle-leaks caught at compile time.

import "std/arc.mc";
import "std/alloc.mc";
import "std/addr.mc";
import "kernel/core/heap.mc";

struct Packet { len: u32, data: [64]u8 }
global g_pool: [8192]u8;

// A consumer: sum the packet's bytes through its shared handle, then release the owner.
// Returns sum, with bit 16 set if this consumer's drop freed the buffer (it was last).
fn consume(a: *Allocator, owner: Arc<Packet>) -> u32 {
    let p: *mut Packet = arc_get(Packet, &owner);
    var sum: u32 = 0;
    var i: usize = 0;
    while i < (p.len as usize) {
        sum = sum + (p.data[i] as u32);
        i = i + 1;
    }
    let freed: bool = arc_drop(Packet, a, owner); // release this owner (consumes it)
    var r: u32 = sum;
    if freed {
        r = r | 0x10000;
    }
    return r;
}

export fn arc_pkt_run() -> u32 {
    var heap: Heap = heap_new(phys_range(pa((&g_pool[0]) as usize), 8192));
    var a: Allocator = heap_allocator(&heap);
    var pass: u32 = 1;

    var owner: Arc<Packet> = arc_new_uninit(Packet, &a); // filled below via arc_get

    // Fill the packet once through the shared handle.
    let p: *mut Packet = arc_get(Packet, &owner);
    p.len = 4;
    p.data[0] = 10;
    p.data[1] = 20;
    p.data[2] = 30;
    p.data[3] = 40; // sum = 100

    // Two owners share the buffer.
    var owner2: Arc<Packet> = arc_clone(Packet, &owner);

    let s1: u32 = consume(&a, owner); // first consumer: reads, drops -> not last
    let s2: u32 = consume(&a, owner2); // second consumer: reads, drops -> frees

    if s1 != 100 {
        pass = 0; // first consumer saw the shared bytes
    }
    if s2 != (100 | 0x10000) {
        pass = 0; // second consumer saw the same bytes AND freed the buffer
    }
    return pass;
}
