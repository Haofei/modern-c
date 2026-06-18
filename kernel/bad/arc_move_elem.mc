// EXPECT: E_MOVE_FIELD_IN_NONMOVE — ArcBlock<T> stores `value: T` by value and arc_drop frees
// the block without a move-aware destructor for T, so a linear `move` T would be duplicated or
// leaked. Instantiating Arc over a move T is rejected here.
import "std/arc.mc";
import "std/alloc.mc";
move struct Res { v: u32 }
fn bad(a: *mut dyn Allocator) -> void {
    switch arc_new(Res, a, .{ .v = 1 }) {
        ok(h) => { arc_drop(Res, h); }
        err(e) => {}
    }
}
