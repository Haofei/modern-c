// Test wrappers around the generic in-place ring buffer, instantiated at Ring<u32>.

import "std/ring.mc";

global g_ring: Ring<u32>;

export fn rg_init() -> void {
    ring_init(u32, &g_ring);
}
export fn rg_push(x: u32) -> u32 {
    if ring_push(u32, &g_ring, x) {
        return 1;
    }
    return 0;
}
export fn rg_pop() -> u32 {
    return ring_pop(u32, &g_ring);
}
export fn rg_len() -> u32 {
    return ring_len(u32, &g_ring) as u32;
}
export fn rg_empty() -> u32 {
    if ring_is_empty(u32, &g_ring) {
        return 1;
    }
    return 0;
}
export fn rg_full() -> u32 {
    if ring_is_full(u32, &g_ring) {
        return 1;
    }
    return 0;
}
