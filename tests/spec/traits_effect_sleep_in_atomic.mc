// SPEC: section=traits
// SPEC: milestone=traits-tier1
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_SLEEP_IN_ATOMIC

// Effect propagation THROUGH monomorphization (docs/traits-design.md §9, review #3):
// a `where T: Sink` generic whose trait method is `#[may_sleep]`, called from an
// `#[irq_context]` fn and instantiated with a concrete impl, must reject — the
// effect is checked at the concrete callee AFTER mono, not laundered past it.

trait Sink {
    #[may_sleep]
    fn flush(self: *Self) -> u32;
}

struct Disk {
    n: u32,
}

impl Sink for Disk {
    #[may_sleep]
    fn flush(self: *Disk) -> u32 {
        return self.n;
    }
}

#[irq_context]
fn drain(comptime T: type, x: *T) -> u32 where T: Sink {
    return T.flush(x); // EXPECT_ERROR: E_SLEEP_IN_ATOMIC
}

export fn traits_effect_sleep() -> u32 {
    var d: Disk = .{ .n = 7 };
    return drain(Disk, &d);
}
