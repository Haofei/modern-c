// SPEC: section=traits
// SPEC: milestone=traits-tier1
// SPEC: phase=parse,sema,lower-c
// SPEC: expect=pass
// SPEC: check=traits-tier1-irq-accept

// Accept dual to the effect-reject (review #3): a non-sleeping `#[irq_context]`
// trait method, instantiated and called from an `#[irq_context]` Tier-1 generic,
// passes — the concrete callee is itself irq-context, so the effect check is
// satisfied after monomorphization (no false positive).

trait Sink {
    #[irq_context]
    fn poke(self: *Self) -> u32;
}

struct Reg {
    n: u32,
}

impl Sink for Reg {
    #[irq_context]
    fn poke(self: *Reg) -> u32 {
        return self.n;
    }
}

#[irq_context]
fn ack(comptime T: type, x: *T) -> u32 where T: Sink {
    return T.poke(x);
}

export fn traits_effect_irq_ok() -> u32 {
    var r: Reg = .{ .n = 7 };
    return ack(Reg, &r);
}
