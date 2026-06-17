// SPEC: section=traits
// SPEC: milestone=traits-tier1
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_TRAIT_SIGNATURE_MISMATCH

// Conformance is FULL-signature equality (review #1): the impl method's RETURN
// TYPE must match the trait signature. The trait declares `-> u32` but the impl
// returns `u64`. Without this check the wrong-typed slot is cast to the trait
// signature at a `*dyn` vtable dispatch — a wild/UB indirect call.

trait Shape {
    fn area(self: *Self) -> u32;
}

struct Square {
    side: u32,
}

impl Shape for Square {
    fn area(self: *Square) -> u64 { // EXPECT_ERROR: E_TRAIT_SIGNATURE_MISMATCH
        return 9;
    }
}
