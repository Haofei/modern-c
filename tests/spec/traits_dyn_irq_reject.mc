// SPEC: section=traits
// SPEC: milestone=traits-tier2
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_IRQ_CONTEXT_CALL

// docs/traits-design.md §6,§9.1 (effect-sound by exclusion): a `*dyn` dispatch is an
// indirect call, and an `#[irq_context]` function may not make an indirect call (the
// target may sleep/block). So a `dyn` call in IRQ context is E_IRQ_CONTEXT_CALL —
// `dyn` cannot launder a forbidden effect into the one place it is forbidden.

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

#[irq_context]
fn in_irq(s: *dyn Shape) -> u32 {
    return s.area(); // EXPECT_ERROR: E_IRQ_CONTEXT_CALL
}
