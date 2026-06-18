// SPEC: section=32.3,32.6
// SPEC: milestone=traits-tier1
// SPEC: phase=parse,sema,lower-c
// SPEC: expect=pass
// SPEC: check=traits-tier1-accept

// Tier 1 traits accept (docs/traits-design.md §2,3): a trait, two impls, and a
// `where T: Trait` bounded generic that calls the trait method. Monomorphizes to
// direct `Type__method` calls — no diagnostics.

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

fn doubled_area(comptime T: type, x: *T) -> u32 where T: Shape {
    return T.area(x) + T.area(x);
}

export fn traits_tier1_accept() -> u32 {
    var s: Square = .{ .side = 3 };
    var r: Rect = .{ .w = 4, .h = 5 };
    let a: u32 = doubled_area(Square, &s); // 9 + 9 = 18
    let b: u32 = doubled_area(Rect, &r);   // 20 + 20 = 40
    if a != 18 {
        return 0;
    }
    if b != 40 {
        return 0;
    }
    return 1;
}
