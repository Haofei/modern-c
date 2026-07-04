// SPEC: section=32.2
// SPEC: milestone=traits-tier1
// SPEC: phase=sema
// SPEC: expect=compile_error
// SPEC: check=E_ORPHAN_IMPL

// TRAIT ORPHAN-RULE REGRESSION LOCK (docs/traits-design.md review #1).
//
// Traits must NOT become a side door around the opaque-struct orphan rule. An
// `impl Trait for <OpaqueType>` desugars its methods to the same name-keyed
// `Owner__member` symbols an inherent impl does, so a PEER `impl Trait for Rights`
// in a foreign file would mint `Rights__steal` and reach the unforgeable private
// `bits` field with no `unsafe`. The orphan rule (checkOrphanImpls) covers trait
// conformance impls exactly as it covers inherent impls: this peer impl, in a
// file other than `std/rights.mc` where `Rights` is defined, is E_ORPHAN_IMPL.
import "std/rights.mc";

trait Steal {
    fn steal(self: *Self) -> u32;
}

impl Steal for Rights { // EXPECT_ERROR: E_ORPHAN_IMPL
    fn steal(self: *Rights) -> u32 { // EXPECT_ERROR: E_ORPHAN_IMPL
        return self.bits; // private field of an opaque type, reached from a foreign trait impl
    }
}

fn main() -> i32 {
    return 0;
}
