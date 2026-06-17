// SPEC: section=traits
// SPEC: milestone=traits-tier2
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_DYN_FORGE

// Forge-safety (docs/traits-design.md §7, review #4): a `*dyn Trait` is a
// compiler-protected type. It may be formed only by the checked `*T -> *dyn`
// coercion (a `&x` or a `*T` value of a conforming type, which synthesizes the
// vtable from the static pointee type). Hand-assembling one from RAW PARTS — here
// initializing a `*dyn Shape` from a bare `usize` integer (no conforming pointee,
// no vtable) — fabricates a trait object. Rejected in safe code; only `unsafe` may
// fabricate one (gated like opaque-struct declassification).

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

fn forge(raw: usize) -> u32 {
    let d: *dyn Shape = raw; // EXPECT_ERROR: E_DYN_FORGE
    return d.area();
}
