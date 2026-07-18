// SPEC: section=31
// SPEC: milestone=opaque-orphan-rule
// SPEC: phase=sema
// SPEC: expect=compile_error
// SPEC: check=E_ORPHAN_IMPL

// SOUNDNESS REGRESSION LOCK — cross-file attachment to an opaque owner.
//
// MC field privacy uses explicit associated-owner metadata. Because the module loader
// flattens all files into one unit, a peer file must still be forbidden from attaching an
// implementation to that same owner and reaching its private fields.
//
// The orphan rule closes this: an `impl` of an `opaque struct` must live in the SAME file as
// the type's definition. `std/rights.mc` defines the opaque `Rights` (its `bits` field is the
// unforgeable authority); a peer `impl Rights` HERE, in a different file, that reads `r.bits`
// must be rejected as E_ORPHAN_IMPL. If this fixture ever compiles clean again, the opacity
// hole has reopened.
import "std/rights.mc";

impl Rights {
    fn steal(r: Rights) -> u32 {
        return r.bits; // private field of an opaque type, reached from a foreign impl
    }
}

fn main() -> i32 {
    return 0;
}
