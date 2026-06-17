// SPEC: section=traits
// SPEC: milestone=traits-tier1
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_TRAIT_SIGNATURE_MISMATCH

// Conformance is FULL-signature equality (review #1): the impl method's ARITY
// (parameter count) must match the trait signature. The trait declares a `k: u32`
// parameter but the impl drops it. A wrong-arity slot cast to the trait signature
// at a `*dyn` vtable dispatch is a wild/UB indirect call (extra argument passed).

trait Shape {
    fn scale(self: *Self, k: u32) -> u32;
}

struct Square {
    side: u32,
}

impl Shape for Square {
    fn scale(self: *Square) -> u32 { // EXPECT_ERROR: E_TRAIT_SIGNATURE_MISMATCH
        return self.side;
    }
}
