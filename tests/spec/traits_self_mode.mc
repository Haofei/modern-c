// SPEC: section=32.1
// SPEC: milestone=traits-tier1
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_TRAIT_SELF_MODE_MISMATCH

// Conformance: the impl method's self-mode must match the trait signature. The
// trait declares `self: *Self` (shared) but the impl takes `self: *mut Square`.

trait Shape {
    fn area(self: *Self) -> u32;
}

struct Square {
    side: u32,
}

impl Shape for Square {
    fn area(self: *mut Square) -> u32 { // EXPECT_ERROR: E_TRAIT_SELF_MODE_MISMATCH
        return self.side * self.side;
    }
}
