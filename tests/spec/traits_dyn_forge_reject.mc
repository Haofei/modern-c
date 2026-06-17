// SPEC: section=traits
// SPEC: milestone=traits-tier2
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_DYN_FORGE

// Forge-safety (docs/traits-design.md §7, review #4): the ONLY way to build a
// `*dyn Trait` in safe code is the checked coercion `&x` / `&mut x`. Initializing a
// `*dyn` from anything else — here a bare `*Square` pointer (no impl-checked coercion,
// no vtable) — would fabricate a trait object. Rejected: `*dyn` is a compiler-protected
// type kind; only `unsafe` may fabricate one (gated like opaque-struct declassification).

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

fn forge(p: *Square) -> u32 {
    let d: *dyn Shape = p; // EXPECT_ERROR: E_DYN_FORGE
    return d.area();
}
