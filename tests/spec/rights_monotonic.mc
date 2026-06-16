// SPEC: section=31
// SPEC: milestone=opaque-struct
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_PRIVATE_FIELD

// K1 — unforgeable + monotonic (narrow-only) capability rights as a TYPE LAW.
//
// This mirrors std/rights' `opaque struct Rights` inline (spec fixtures are parsed
// standalone, without imports). The point: an `opaque struct`'s bit set is private to its
// own `impl`, so code OUTSIDE that `impl` cannot:
//   - FORGE a rights value by constructing it from a raw integer (`.{ .bits = 0xFF }`),
//   - WIDEN one by reading its field and OR-ing a new bit in,
//   - inspect/replace the field to manufacture authority.
// Each is `E_PRIVATE_FIELD`. The ONLY way to combine rights is `attenuate`, which ANDs —
// it can only CLEAR bits, so a sub-grant is always ⊆ its parent. There is no widening dual,
// so least-privilege attenuation is enforced by the type system, not by convention.

opaque struct Rights {
    bits: u32,
}

impl Rights {
    // privileged root mint (authority enters here)
    fn grant(bits: u32) -> Rights { return .{ .bits = bits }; }
    // the only combinator: narrow-only (result = r ∩ keep, so result ⊆ r)
    fn attenuate(r: Rights, keep: Rights) -> Rights { return .{ .bits = r.bits & keep.bits }; }
    fn attenuate_mask(r: Rights, keep_bits: u32) -> Rights { return .{ .bits = r.bits & keep_bits }; }
    fn allows(r: Rights, b: u32) -> bool { return (r.bits & (1 << b)) != 0; }
    fn subset_of(child: Rights, parent: Rights) -> bool { return (child.bits & (~parent.bits)) == 0; }
}

// --- accepted: the legitimate API. Mint, attenuate (narrow), query. No field access. ---

fn accept_mint_and_query() -> bool {
    let full: Rights = Rights.grant(0x7); // privileged root mint: rights {0,1,2}
    return Rights.allows(full, 1);
}

fn accept_attenuate_narrows() -> bool {
    let parent: Rights = Rights.grant(0x7);                          // {0,1,2}
    let child: Rights = Rights.attenuate(parent, Rights.grant(0x3)); // ∩ {0,1} = {0,1}
    // The child is a strict subset of the parent: it lost right 2, gained nothing.
    let narrowed: bool = !Rights.allows(child, 2);
    let still_subset: bool = Rights.subset_of(child, parent);
    return narrowed && still_subset;
}

fn accept_attenuate_cannot_regain() -> bool {
    // Attenuating with a mask that includes bits the parent lacks does NOT add them:
    // {0,1} ∩ {0,1,2,3} = {0,1}. `keep` can only remove, never restore.
    let parent: Rights = Rights.grant(0x3);                 // {0,1}
    let child: Rights = Rights.attenuate_mask(parent, 0xF); // ∩ {0,1,2,3} = {0,1}
    return !Rights.allows(child, 2) && !Rights.allows(child, 3);
}

// --- rejected: FORGING a rights value from a raw bit set outside the `impl` ---
fn reject_forge_from_raw() -> Rights {
    // EXPECT_ERROR: E_PRIVATE_FIELD
    return .{ .bits = 0xFFFF_FFFF };
}

// --- rejected: WIDENING by reading the private field (to then OR a bit) ---
fn reject_read_bits(r: Rights) -> u32 {
    // EXPECT_ERROR: E_PRIVATE_FIELD
    return r.bits;
}

// --- rejected: writing the private field to set new bits (widen in place) ---
fn reject_widen_in_place(r: Rights) -> bool {
    var rr: Rights = r;
    // EXPECT_ERROR: E_PRIVATE_FIELD
    rr.bits = 0xFFFF_FFFF;
    return Rights.allows(rr, 31);
}
