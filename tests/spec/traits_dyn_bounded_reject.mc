// SPEC: section=32.5
// SPEC: milestone=traits-tier2
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_UNBOUNDED_INDIRECT_CALL

// traits-design review #2 (T(term)1 extension): a `*dyn` dispatch inside a `#[bounded]`
// function is rejected — the termination check cannot see through the vtable to bound
// the callee, so `dyn` cannot smuggle unbounded behavior into a bounded context. The
// exclusion is uniform with the IRQ exclusion (both are effect-restricted contexts).

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

#[bounded]
fn in_bounded(s: *dyn Shape) -> u32 {
    return s.area(); // EXPECT_ERROR: E_UNBOUNDED_INDIRECT_CALL
}
