// EXPECT: E_USE_AFTER_MOVE
// Moving a linear `move` value out THROUGH a pointer deref must be rejected. The
// checker tracks the owning binding `o`, not the pointee of `p`, so if `own_free(Cell, *p)`
// were modeled as a borrow (the old behavior) the binding `o` would still look live and the
// trailing `own_free(Cell, o)` would compile into a DOUBLE FREE of the same allocation.
// Found by the Phase-3 adversarial move-checker audit; the fix rejects the move-out-of-deref
// at src/sema_move.zig (the `.deref` arm of moveConsume) so the alias free can never pair
// with a direct free to double-release. A scalar (non-move) deref `f(*p)` stays a plain borrow.
import "std/alloc.mc";
import "std/addr.mc";
import "kernel/core/heap.mc";
global g_pool: [4096]u8;
struct Cell { v: u32 }
fn bad() -> void {
    var heap: Heap = heap_new(phys_range(pa((&g_pool[0]) as usize), 4096));
    let a: *mut dyn Allocator = heap_allocator(&heap);
    var o: Owned<Cell> = create(Cell, a);
    var p: *mut Owned<Cell> = &o;
    own_free(Cell, *p);
    own_free(Cell, o);
}
