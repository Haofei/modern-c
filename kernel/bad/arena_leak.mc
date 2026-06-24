// EXPECT: E_RESOURCE_LEAK — a move Arena is never destroyed (the arena itself leaks).
import "std/alloc/arena.mc";
import "std/addr.mc";
global g_pool: [4096]u8;
fn bad() -> void {
    var a: Arena = arena_init(phys_range(pa((&g_pool[0]) as usize), 4096));
    let p: PAddr = arena_alloc(&a, 16, 8);
}
