// SPEC: section=traits
// SPEC: milestone=traits-tier1
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_TRAIT_INCOHERENT,E_DUPLICATE_DECLARATION

// Coherence: at most one `impl Trait for Type` per (Trait, Type) pair. A second
// impl is E_TRAIT_INCOHERENT (and, because both desugar to `Square__area`, also a
// duplicate top-level declaration).

trait Shape {
    fn area(self: *Self) -> u32;
}

struct Square {
    side: u32,
}

impl Shape for Square {
    fn area(self: *Square) -> u32 {
        return self.side;
    }
}

impl Shape for Square { // EXPECT_ERROR: E_TRAIT_INCOHERENT
    fn area(self: *Square) -> u32 { // EXPECT_ERROR: E_DUPLICATE_DECLARATION
        return self.side + 1;
    }
}
