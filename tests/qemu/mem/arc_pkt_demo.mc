// Step 4: a shared network buffer. A received packet is Arc-shared between two
// consumers (e.g. the protocol layer and a logger). Each reads the same bytes through
// its own owner and releases it; the buffer is freed exactly when the last owner drops
// — the skb/mbuf refcount pattern, with handle-leaks caught at compile time.

import "std/collections/arc.mc";
import "std/alloc/alloc.mc";
import "std/addr.mc";
import "kernel/core/heap.mc";

struct Packet { len: u32, data: [64]u8 }
global g_pool: [8192]u8;

fn packet_init(owner: *Arc<Packet>) -> void {
    var p: *mut Packet = uninit;
    unsafe {
        p = arc_get_mut(Packet, owner);
    }
    p.len = 4;
    p.data[0] = 10;
    p.data[1] = 20;
    p.data[2] = 30;
    p.data[3] = 40; // sum = 100
}

fn packet_sum_addr(block: PAddr) -> u32 {
    var p: *const Packet = uninit;
    unsafe {
        p = raw.ptr<Packet>(block);
    }
    var sum: u32 = 0;
    var i: usize = 0;
    while i < (p.len as usize) {
        sum = sum + (p.data[i] as u32);
        i = i + 1;
    }
    return sum;
}

fn mark_freed(sum: u32, freed: bool) -> u32 {
    var r: u32 = sum;
    if freed {
        r = r | 0x10000;
    }
    return r;
}

export fn arc_pkt_run() -> u32 {
    var heap: Heap = uninit;
    heap_init(&heap, phys_range(pa((&g_pool[0]) as usize), 8192));
    let a: *mut dyn Allocator = heap_allocator(&heap);
    var pass: u32 = 1;

    var owner: Arc<Packet> = arc_new_uninit(Packet, a); // filled below via arc_get_mut

    // Fill the packet once while this handle is still unique. arc_get_mut is unsafe (the
    // checker can't prove no clone aliases the pointer); we do not clone `owner` until after.
    packet_init(&owner);

    // Two owners share the buffer.
    var owner2: Arc<Packet> = arc_clone_from_parts(Packet, owner.block, owner.allocator);

    let s1_sum: u32 = packet_sum_addr(owner.block);
    let s1_freed: bool = arc_drop(Packet, move owner); // first consumer: reads, drops -> not last
    let s1: u32 = mark_freed(s1_sum, s1_freed);
    let s2_sum: u32 = packet_sum_addr(owner2.block);
    let s2_freed: bool = arc_drop(Packet, move owner2); // second consumer: reads, drops -> frees
    let s2: u32 = mark_freed(s2_sum, s2_freed);

    if s1 != 100 {
        pass = 0; // first consumer saw the shared bytes
    }
    if s2 != (100 | 0x10000) {
        pass = 0; // second consumer saw the same bytes AND freed the buffer
    }
    return pass;
}
