// Tier 2 traits (docs/traits-design.md §4,5,7,8): `*dyn Trait` trait objects with
// a compiler-emitted rodata vtable and fat-pointer dispatch — the dynamic-dispatch
// counterpart to the Tier 1 demo's monomorphized direct calls.
//
// `Shape` is object-safe (one borrow-self method). Two impls (Square, Rect) compute
// different areas. We build `*dyn Shape` values via the CHECKED coercion `&x` from
// concrete stack objects (NO heap — the vtable is `static const` rodata), store a
// HETEROGENEOUS array of `*dyn Shape`, and dispatch `s.area()` through the vtable in
// a loop. Each element resolves to a DIFFERENT impl via its own vtable pointer, so a
// wrong dispatch changes the digest. This is a genuine indirect call: the array mixes
// Square and Rect, so the call cannot be devirtualized to a single target.

trait Shape {
    fn area(self: *Self) -> u32;
    fn sides(self: *Self) -> u32;
}

struct Square {
    side: u32,
}

struct Rect {
    w: u32,
    h: u32,
}

impl Shape for Square {
    fn area(self: *Square) -> u32 {
        return self.side * self.side;
    }
    fn sides(self: *Square) -> u32 {
        return 4;
    }
}

impl Shape for Rect {
    fn area(self: *Rect) -> u32 {
        return self.w * self.h;
    }
    fn sides(self: *Rect) -> u32 {
        return 4;
    }
}

export fn dyn_run() -> u32 {
    var sq1: Square = .{ .side = 3 };    // area 9
    var rc1: Rect = .{ .w = 5, .h = 6 }; // area 30
    var sq2: Square = .{ .side = 4 };    // area 16
    var rc2: Rect = .{ .w = 2, .h = 7 }; // area 14

    // The checked coercion: `&x` -> `*dyn Shape` emits {data=&x, vtable=&__vt_Type_Shape}.
    // Safe code cannot fabricate the vtable; only an impl-backed `&x` reaches `*dyn`.
    var shapes: [4]*dyn Shape = .{ &sq1, &rc1, &sq2, &rc2 };

    // Dispatch `s.area()` through the vtable over a HETEROGENEOUS array — each element
    // resolves to a different impl via its own vtable pointer, so the call is a genuine
    // load-through-vtable indirect call (not devirtualizable to one target).
    var sum: u32 = 0;
    var sides_sum: u32 = 0;
    var i: usize = 0;
    while i < 4 {
        let s: *dyn Shape = shapes[i];
        sum = sum + s.area();       // 9 + 30 + 16 + 14 = 69
        sides_sum = sides_sum + s.sides(); // 4 * 4 = 16 (second vtable slot)
        i = i + 1;
    }
    let digest: u32 = sum * 1000 + sides_sum; // 69 * 1000 + 16 = 69016

    if sum != 69 {
        return 0;
    }
    if sides_sum != 16 {
        return 0;
    }
    if digest != 69016 {
        return 0;
    }
    return 1;
}
