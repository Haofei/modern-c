// SPEC: section=traits
// SPEC: milestone=traits-tier2
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_DYN_MOVE_SELF,E_TRAIT_NOT_OBJECT_SAFE

// docs/traits-design.md §5: a consuming (`move self`) method is static-dispatch only.
// Calling it THROUGH a `*dyn` is E_DYN_MOVE_SELF (you cannot move out of a borrowed
// trait object). The `*dyn Consume` parameter is itself non-object-safe
// (E_TRAIT_NOT_OBJECT_SAFE), so both diagnostics fire — one per offending construct.

trait Consume {
    fn take(move self) -> u32;
}

fn use_dyn(c: *dyn Consume) -> u32 { // EXPECT_ERROR: E_TRAIT_NOT_OBJECT_SAFE
    return c.take(); // EXPECT_ERROR: E_DYN_MOVE_SELF
}
