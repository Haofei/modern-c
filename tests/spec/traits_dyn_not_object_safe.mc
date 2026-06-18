// SPEC: section=32.4
// SPEC: milestone=traits-tier2
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_TRAIT_NOT_OBJECT_SAFE

// Object safety (docs/traits-design.md §5): a trait with a `move self` method is NOT
// object-safe — you cannot move out of a borrowed trait object. Forming `*dyn Consume`
// is rejected. (The trait is still fully usable via Tier 1.)

// A `move self` method makes the whole trait non-object-safe (move-self methods are
// static-dispatch only); `move self` is legal only in a trait signature, not an impl.
trait Consume {
    fn take(move self) -> u32;
}

fn register(c: *dyn Consume) -> u32 { // EXPECT_ERROR: E_TRAIT_NOT_OBJECT_SAFE
    return 0;
}
