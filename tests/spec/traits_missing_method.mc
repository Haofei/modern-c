// SPEC: section=traits
// SPEC: milestone=traits-tier1
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_TRAIT_MISSING_METHOD

// Conformance: an `impl Trait for Type` must provide EXACTLY the trait's methods.
// Here `perimeter` is missing -> E_TRAIT_MISSING_METHOD on the impl's type.

trait Shape {
    fn area(self: *Self) -> u32;
    fn perimeter(self: *Self) -> u32;
}

struct Square {
    side: u32,
}

impl Shape for Square { // EXPECT_ERROR: E_TRAIT_MISSING_METHOD
    fn area(self: *Square) -> u32 {
        return self.side * self.side;
    }
}
