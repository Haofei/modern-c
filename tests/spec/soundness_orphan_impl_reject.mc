// SPEC: section=31
// SPEC: milestone=opaque-orphan-rule
// SPEC: phase=sema
// SPEC: expect=compile_error
// SPEC: check=E_ORPHAN_IMPL

// SOUNDNESS REGRESSION LOCK — the systemic name-keyed opacity bypass.
//
// MC field privacy for an `opaque struct` is decided purely on the (mangled) symbol name:
// a function named `Owner__member` may read `Owner`'s private fields. Because the module
// loader flattens all files into ONE unit with no module visibility, any file could write a
// PEER `impl <OpaqueType>` and mint the same `Owner__member` symbol — reaching the private
// field with NO `unsafe`, defeating Cap/Rights/Tainted/Guarded/Guard opacity wholesale.
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
