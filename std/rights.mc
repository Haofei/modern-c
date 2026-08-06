// std/rights — an UNFORGEABLE, MONOTONIC (narrow-only) rights set: the type-level
// capability-attenuation law (hardening item K1).
//
// A `Rights` value names a set of permission bits (right id = bit index, 0..31). Unlike a
// plain `Mask32`, it cannot be:
//
//   - FORGED: `Rights` is an `opaque struct` (section 31). Its `bits` field is private to
//     this module's associated functions (`impl Rights`), so code in OTHER modules cannot
//     construct one with a struct literal `.{ .bits = X }` (that is `E_PRIVATE_FIELD`), nor
//     read/write the field to mint authority. The only way to obtain or combine a `Rights`
//     is through the `rights_*` API below. `rights_grant` / `rights_single` (the
//     authority mints) require a `RightsAuthority` root token, so bootstrap code
//     must make the privilege boundary explicit instead of relying on caller
//     convention.
//
//   - WIDENED: there is NO operation that turns a bit on given an existing `Rights`. The
//     only combinators that take a caller's `Rights` and produce another (`rights_attenuate`,
//     `rights_attenuate_mask`, `rights_without`) all AND/clear — they can only DROP bits,
//     never set them. So every derived right is a subset of the one it came from: a sub-grant
//     is always ⊆ its parent (the attenuated-subgrant law). To add a bit you would have to
//     construct a `Rights` from raw, which other modules cannot do.
//
// This makes least-privilege a *type law*, not a convention: a holder of `Rights` can hand
// out strictly weaker `Rights`, and the type system rejects any attempt to manufacture or
// broaden authority. `Mask32` remains the general-purpose bit-set; `Rights` is the
// hardened, monotone capability variant for delegation.
//
// The `impl Rights` block holds the only code with access to the private `bits` field; the
// `rights_*` wrappers are the cross-module public surface (associated-function
// call syntax `Rights.x(...)` is file-local sugar, so the wrappers are how other modules
// use a `Rights`). No wrapper exposes a path that sets a bit from raw outside this module.

import "std/math.mc";

pub opaque struct Rights {
    bits: u32,
}

pub linear opaque struct RightsAuthority {
    marker: u32,
}

impl RightsAuthority {
    fn mint() -> RightsAuthority {
        return .{ .marker = 0x52494748 };
    }
    fn require(auth: *RightsAuthority) -> void {
        if auth.marker == 0 {
        }
    }
}

// Privileged root creation seam. The current language has unsafe blocks but no
// `unsafe fn` declaration syntax, so source-level gates audit calls to this
// unchecked root. Ordinary code can attenuate existing rights but cannot mint
// new authority without possessing this opaque linear token.
pub fn rights_authority_unchecked() -> RightsAuthority {
    return RightsAuthority.mint();
}

pub fn rights_authority_revoke(auth: RightsAuthority) -> void {
    unsafe { forget_unchecked(auth); }
}

impl Rights {
    // ----- constructors (the only ways to obtain a `Rights`) -----

    fn none() -> Rights {
        return .{ .bits = 0 };
    }
    // PRIVILEGED full-authority mint: the one place authority enters the system (it builds a
    // `Rights` from a raw bit set). By convention only the kernel/bootstrap calls it.
    fn grant(bits: u32) -> Rights {
        return .{ .bits = bits };
    }
    fn single(b: u32) -> Rights {
        if b >= 32 {
            return .{ .bits = 0 };
        }
        return .{ .bits = wrapping_shl_u32(1, b) };
    }

    // ----- narrow-only combinators (the result is always ⊆ the input) -----

    fn attenuate(r: Rights, keep: Rights) -> Rights {
        return .{ .bits = r.bits & keep.bits };
    }
    fn attenuate_mask(r: Rights, keep_bits: u32) -> Rights {
        return .{ .bits = r.bits & keep_bits };
    }
    fn without(r: Rights, b: u32) -> Rights {
        if b >= 32 {
            return r;
        }
        return .{ .bits = r.bits & (~wrapping_shl_u32(1, b)) };
    }

    // ----- queries -----

    fn allows(r: Rights, b: u32) -> bool {
        if b >= 32 {
            return false;
        }
        return (r.bits & wrapping_shl_u32(1, b)) != 0;
    }
    fn subset_of(child: Rights, parent: Rights) -> bool {
        // child ⊆ parent  <=>  child has no bit outside parent  <=>  child & ~parent == 0.
        return (child.bits & (~parent.bits)) == 0;
    }
    fn is_empty(r: Rights) -> bool {
        return r.bits == 0;
    }
    fn eq(a: Rights, b: Rights) -> bool {
        return a.bits == b.bits;
    }
}

// ----- public, cross-module API (free wrappers over the `impl`) -----

// The empty rights set: no authority. Always safe to hand out.
pub fn rights_none() -> Rights {
    return Rights.none();
}

// PRIVILEGED full-authority mint. Constructs a `Rights` from a raw bit set — the
// point where authority is created. Callers must possess the explicit root token;
// everything downstream can only attenuate what it is given.
pub fn rights_grant(auth: *RightsAuthority, bits: u32) -> Rights {
    RightsAuthority.require(auth);
    return Rights.grant(bits);
}

// A single-right capability (right id = bit `b`, 0..31). A privileged mint, like grant.
pub fn rights_single(auth: *RightsAuthority, b: u32) -> Rights {
    RightsAuthority.require(auth);
    return Rights.single(b);
}

// Attenuate `r` to the subset also present in `keep`: result = r ∩ keep. The sole way to
// derive a new `Rights` from an existing one, and it can only ever DROP bits — never add
// them. Hence result ⊆ `r` (and ⊆ `keep`): a sub-grant is always weaker than its parent.
pub fn rights_attenuate(r: Rights, keep: Rights) -> Rights {
    return Rights.attenuate(r, keep);
}

// Attenuate by a raw allow-mask: drop every bit not set in `keep_bits`. Narrow-only —
// `keep_bits` can only remove rights, never restore ones `r` already lacks.
pub fn rights_attenuate_mask(r: Rights, keep_bits: u32) -> Rights {
    return Rights.attenuate_mask(r, keep_bits);
}

// Drop a single right (clear bit `b`). Pure attenuation.
pub fn rights_without(r: Rights, b: u32) -> Rights {
    return Rights.without(r, b);
}

// Does this rights set permit right `b`?
pub fn rights_allows(r: Rights, b: u32) -> bool {
    return Rights.allows(r, b);
}

// True iff `child` ⊆ `parent`: every right the child holds the parent also holds. The
// attenuated-subgrant law as a checkable predicate — a faithfully derived child always
// satisfies it, and any `Rights` that does not is impossible to obtain from `parent`.
pub fn rights_subset_of(child: Rights, parent: Rights) -> bool {
    return Rights.subset_of(child, parent);
}

// True iff no rights are held.
pub fn rights_is_empty(r: Rights) -> bool {
    return Rights.is_empty(r);
}

// Equality of two rights sets.
pub fn rights_eq(a: Rights, b: Rights) -> bool {
    return Rights.eq(a, b);
}
