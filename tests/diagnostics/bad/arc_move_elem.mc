// EXPECT: E_RAW_RESOURCE_PAYLOAD — ArcBlock<T> stores `value: T` by value behind a raw
// allocation block. Instantiating Arc over a move T would let raw.ptr expose ownership
// storage outside a typed move-aware API, so it is rejected here.
import "std/collections/arc.mc";
import "std/alloc/alloc.mc";
move struct Res { v: u32 }
fn bad(a: *mut dyn Allocator) -> void {
    let h: Arc<Res> = arc_new(Res, a, .{ .v = 1 });
    arc_drop(Res, move h);
}
