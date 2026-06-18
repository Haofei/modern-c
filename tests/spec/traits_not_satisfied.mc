// SPEC: section=32.3
// SPEC: milestone=traits-tier1
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_TRAIT_NOT_SATISFIED

// Bound satisfaction is checked at the INSTANTIATION SITE (not deep in the body):
// instantiating `where T: Shape` with a non-conforming `Circle` names the unmet bound.

trait Shape {
    fn area(self: *Self) -> u32;
}

struct Square {
    side: u32,
}

struct Circle {
    r: u32,
}

impl Shape for Square {
    fn area(self: *Square) -> u32 {
        return self.side * self.side;
    }
}

fn use_shape(comptime T: type, x: *T) -> u32 where T: Shape {
    return T.area(x);
}

export fn traits_not_satisfied() -> u32 {
    var c: Circle = .{ .r = 5 };
    return use_shape(Circle, &c); // EXPECT_ERROR: E_TRAIT_NOT_SATISFIED
}
