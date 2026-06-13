// EXPECT: E_MOVE_ARRAY_UNSUPPORTED — a generic container that stores its element by value
// cannot hold a linear `move` type: pool_load/pool_set would duplicate or leak the resource.
// Pool<T> stores [N]T by value, so instantiating it over a move T is rejected here.
import "std/pool.mc";
move struct Res { v: u32 }
global g_pool: Pool<Res, 4>;
fn bad() -> void {
    pool_init(Res, 4, &g_pool);
}
