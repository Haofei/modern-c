// SPEC: section=32.4
// SPEC: milestone=traits-tier2
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_DYN_FORGE

// Forge-safety is UNIFORM across assignment contexts (review #2,#4): forging a
// `*dyn Trait` from raw parts is rejected at a STRUCT FIELD init too. Here a
// `*dyn Shape` field is fabricated from a bare `usize`.

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

struct Holder {
    inner: *dyn Shape,
}

fn forge_field(raw: usize) -> u32 {
    let h: Holder = .{ .inner = raw }; // EXPECT_ERROR: E_DYN_FORGE
    return h.inner.area();
}
