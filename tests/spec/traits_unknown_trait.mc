// SPEC: section=32.1,32.4
// SPEC: milestone=traits-tier1
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_UNKNOWN_TRAIT

struct Square {
    side: u32,
}

impl MissingTrait for Square { // EXPECT_ERROR: E_UNKNOWN_TRAIT
    fn area(self: *Square) -> u32 {
        return self.side * self.side;
    }
}

fn reject_unknown_dyn_trait(s: *dyn MissingDyn) -> u32 { // EXPECT_ERROR: E_UNKNOWN_TRAIT
    return 0;
}
