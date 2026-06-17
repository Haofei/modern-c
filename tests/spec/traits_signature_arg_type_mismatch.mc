// SPEC: section=traits
// SPEC: milestone=traits-tier1
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_TRAIT_SIGNATURE_MISMATCH

// Conformance is FULL-signature equality (review #1): EACH parameter type of the
// impl method must match the trait signature. The trait declares `k: u32` but the
// impl takes `k: u64`. A wrong-typed slot cast to the trait signature at a `*dyn`
// vtable dispatch is a wild/UB indirect call.

trait Shape {
    fn scale(self: *Self, k: u32) -> u32;
}

struct Square {
    side: u32,
}

impl Shape for Square {
    fn scale(self: *Square, k: u64) -> u32 { // EXPECT_ERROR: E_TRAIT_SIGNATURE_MISMATCH
        return self.side;
    }
}
