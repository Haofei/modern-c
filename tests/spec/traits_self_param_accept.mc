// SPEC: section=32.1,32.3
// SPEC: milestone=traits-tier1
// SPEC: phase=parse,sema,lower-c
// SPEC: expect=pass
// SPEC: check=traits-tier1-accept

// Language gap G16: a trait method may write `Self` in a NON-receiver parameter
// position. Trait-conformance checking substitutes `Self` for the concrete impl
// type in EVERY parameter (and the return type), not just the receiver, so the
// impl's `other: *IntKey` conforms to the trait's `other: *Self`. The bounded
// generic `keq` then type-checks and monomorphizes `K.eq` to `IntKey__eq`.

trait Keyed {
    fn hash(self: *Self) -> u32;
    fn eq(self: *Self, other: *Self) -> bool;   // `other: *Self` in a param slot
}

struct IntKey {
    v: u32,
}

impl Keyed for IntKey {
    fn hash(self: *IntKey) -> u32 {
        return self.v * 7;
    }
    fn eq(self: *IntKey, other: *IntKey) -> bool {
        return self.v == other.v;
    }
}

fn keq(comptime K: type, a: *K, b: *K) -> bool where K: Keyed {
    return K.eq(a, b);
}

export fn traits_self_param_accept() -> u32 {
    var x: IntKey = .{ .v = 7 };
    var y: IntKey = .{ .v = 7 };
    if keq(IntKey, &x, &y) {
        return 1;
    }
    return 0;
}
