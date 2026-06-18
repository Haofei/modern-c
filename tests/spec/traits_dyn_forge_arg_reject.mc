// SPEC: section=32.4
// SPEC: milestone=traits-tier2
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_DYN_FORGE

// Forge-safety is UNIFORM across assignment contexts (review #2,#4): forging a
// `*dyn Trait` from raw parts is rejected at a CALL ARGUMENT too. Here a `*dyn
// Shape` argument is fabricated from a bare `usize`.

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
}

fn use_dyn(d: *dyn Shape) -> u32 {
    return d.area();
}

fn forge_arg(raw: usize) -> u32 {
    return use_dyn(raw); // EXPECT_ERROR: E_DYN_FORGE
}
