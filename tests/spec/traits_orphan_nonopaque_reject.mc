// SPEC: section=32.2
// SPEC: milestone=traits-tier1
// SPEC: phase=sema
// SPEC: expect=compile_error
// SPEC: check=E_ORPHAN_IMPL

// Trait orphan-rule regression lock for non-opaque nominal types.
//
// The spec makes `impl Trait for Type` live with the file that declares `Type`,
// not just with opaque types. `Arena` is a public, non-opaque type declared in
// std/alloc/arena.mc, so a peer trait impl here must be rejected.
import "std/alloc/arena.mc";

trait Metered {
    fn capacity(self: *Arena) -> usize;
}

impl Metered for Arena { // EXPECT_ERROR: E_ORPHAN_IMPL
    fn capacity(self: *Arena) -> usize {
        return 0;
    }
}

fn main() -> i32 {
    return 0;
}
