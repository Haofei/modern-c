// SPEC: section=32.1
// SPEC: milestone=traits-tier1
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_TRAIT_UNKNOWN_METHOD

trait Shape {
    fn area(self: *Self) -> u32;
}

struct Square {
    side: u32,
}

impl Shape for Square {
    fn area(self: *Square) -> u32 {
        return self.side * self.side;
    }

    fn perimeter(self: *Square) -> u32 { // EXPECT_ERROR: E_TRAIT_UNKNOWN_METHOD
        return self.side * 4;
    }
}
