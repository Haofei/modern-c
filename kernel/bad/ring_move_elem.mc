// EXPECT: E_MOVE_ARRAY_UNSUPPORTED — Ring<T> stores [N]T by value and ring_front/ring_pop copy
// an element out, which would duplicate a linear `move` resource. Instantiating it over a move
// T is rejected here; use a move-aware container or hold the resource behind a pointer.
import "std/ring.mc";
move struct Res { v: u32 }
global g_ring: Ring<Res, 4>;
fn bad() -> void {
    ring_init(Res, 4, &g_ring);
}
