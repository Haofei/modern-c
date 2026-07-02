// SPEC: section=32.1
// SPEC: milestone=traits-tier1
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_TRAIT_SIGNATURE_MISMATCH

// G16 must not weaken conformance for GENUINE mismatches. `Self` in a trait
// parameter position stands for the impl type ONLY — an impl that writes a
// different concrete type in that slot (`other: *Other` where the trait says
// `other: *Self`, i.e. `*IntKey`) is still rejected. If this were accepted, a
// `*dyn` vtable slot cast to the trait signature would become a wild/UB call.

trait Keyed {
    fn eq(self: *Self, other: *Self) -> bool;
}

struct IntKey {
    v: u32,
}

struct Other {
    w: u32,
}

impl Keyed for IntKey {
    fn eq(self: *IntKey, other: *Other) -> bool { // EXPECT_ERROR: E_TRAIT_SIGNATURE_MISMATCH
        return self.v == other.w;
    }
}
