// Tier 1 traits (docs/traits-design.md §2,3): a `trait Shape` with two `impl`s
// (Square, Rect) of different areas, and a `where T: Shape` generic `total_area`
// that calls the trait method `T.area(item)`. After monomorphization the bounded
// call lowers to a DIRECT call to `Square__area` / `Rect__area` — zero runtime
// dispatch, no vtable. The digest below depends on the dispatched results, so a
// wrong dispatch (or a wrong area) changes the output.

trait Shape {
    fn area(self: *Self) -> u32;
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
}

impl Shape for Rect {
    fn area(self: *Rect) -> u32 {
        return self.w * self.h;
    }
}

// Bounded generic: sums the areas of two shapes of the same concrete type T.
// `T.area(a)` resolves (at instantiation) to a direct call to T's impl method.
fn sum_two(comptime T: type, a: *T, b: *T) -> u32 where T: Shape {
    return T.area(a) + T.area(b);
}

export fn traits_run() -> u32 {
    var s1: Square = .{ .side = 3 };   // area 9
    var s2: Square = .{ .side = 4 };   // area 16
    var r1: Rect = .{ .w = 5, .h = 6 };    // area 30
    var r2: Rect = .{ .w = 2, .h = 7 };    // area 14

    let sq_total: u32 = sum_two(Square, &s1, &s2); // 9 + 16 = 25
    let rc_total: u32 = sum_two(Rect, &r1, &r2);   // 30 + 14 = 44

    // A digest that depends on each dispatched result distinctly.
    let digest: u32 = sq_total * 1000 + rc_total; // 25044

    if sq_total != 25 {
        return 0;
    }
    if rc_total != 44 {
        return 0;
    }
    if digest != 25044 {
        return 0;
    }
    return 1;
}
