// kernel/core/capability — capability-based least privilege (the MINIX lesson, made
// stronger by MC's linear types). A `Cap<R>` is an *unforgeable, linear* grant of
// access to a resource R (e.g. a device's MMIO base, an IRQ line, a memory region):
//
//   - unforgeable: `Cap` is an `opaque move struct` (section 31), so its `resource` field is
//     private to this module — outside code CANNOT construct one with a struct literal
//     `.{ .resource = X }` (that is `E_PRIVATE_FIELD`). `cap_mint` is the only constructor,
//     and it is the kernel's setup-time primitive, so possession is the audit point;
//   - linear (`move`): a cap has exactly one owner and cannot be copied, so a process
//     without the cap simply cannot name the resource — it must ask the server that
//     holds it (via IPC). Transfer is explicit (move into a spawn or an IPC handoff).
//
// This is least privilege enforced by the type system: in MINIX the kernel checks a
// privilege table at runtime; here a driver that doesn't hold `Cap<Mmio>` can't even
// express the access — and cannot forge one.
//
// `RCap<R>` (below) extends a cap with an UNFORGEABLE, MONOTONIC rights set (std/rights):
// the same resource handle, plus an attenuable `Rights`. Sub-grants can only NARROW the
// rights (never widen) — the attenuated-subgrant property as a type law (hardening K1).

import "std/rights.mc";

opaque move struct Cap<R> {
    resource: R,
}

impl Cap {
    // The privileged mint: construct a capability over `resource`. Inside the `impl`, so it
    // is the one place a `Cap` can be built — outside code has no struct-literal path.
    fn mint(comptime R: type, resource: R) -> Cap<R> {
        return .{ .resource = resource };
    }
    // Borrow the cap to read the granted resource. Does not consume it.
    fn resource_of(comptime R: type, c: *Cap<R>) -> R {
        return c.resource;
    }
}

// Grant a capability over `resource` (the kernel's setup-time primitive). Thin wrapper over
// the privileged `Cap.mint` so the public name and call shape are unchanged.
export fn cap_mint(comptime R: type, resource: R) -> Cap<R> {
    return Cap.mint(R, resource);
}

// Use the capability: borrow it to read the granted resource. Does not consume it.
export fn cap_resource(comptime R: type, c: *Cap<R>) -> R {
    return Cap.resource_of(R, c);
}

// Revoke the capability, consuming it (its linear end of life).
export fn cap_revoke(comptime R: type, c: Cap<R>) -> void {
    unsafe { forget_unchecked(c); } // husk: a capability owns nothing to release
}

// ----- rights-bearing capability: resource handle + unforgeable, narrow-only Rights -----
//
// An `RCap<R>` is a `Cap`-style unforgeable, linear grant that additionally carries a
// `Rights` set (std/rights) describing WHICH operations the holder may perform on the
// resource. Because both the `RCap` and its `Rights` are opaque + monotone:
//
//   - it cannot be forged (no struct-literal path outside this `impl`, and `Rights` itself
//     cannot be minted from raw outside std/rights);
//   - its rights can only be NARROWED: `rcap_attenuate` derives a child cap whose rights are
//     `parent_rights ∩ keep` — a subset, never a superset. There is no widening operation.
//
// This is the attenuated-subgrant law made structural: a holder can delegate a strictly
// weaker capability and the type system rejects any attempt to broaden one.

opaque move struct RCap<R> {
    resource: R,
    rights: Rights,
}

impl RCap {
    // Privileged mint: grant a rights-bearing capability over `resource` with `rights`. The
    // `rights` must itself have been obtained through std/rights (which gates minting), so
    // authority enters only through the privileged roots.
    fn mint(comptime R: type, resource: R, rights: Rights) -> RCap<R> {
        return .{ .resource = resource, .rights = rights };
    }
    // Borrow to read the granted resource. Does not consume the cap.
    fn resource_of(comptime R: type, c: *RCap<R>) -> R {
        return c.resource;
    }
    // Borrow to read the cap's rights set (a copyable `Rights`). Does not consume the cap.
    fn rights_of(comptime R: type, c: *RCap<R>) -> Rights {
        return c.rights;
    }
}

// Mint a rights-bearing capability (kernel setup-time primitive).
export fn rcap_mint(comptime R: type, resource: R, rights: Rights) -> RCap<R> {
    return RCap.mint(R, resource, rights);
}

// Read the resource a rights-bearing cap grants. Borrows; does not consume.
export fn rcap_resource(comptime R: type, c: *RCap<R>) -> R {
    return RCap.resource_of(R, c);
}

// Read the rights a cap carries. Borrows; does not consume.
export fn rcap_rights(comptime R: type, c: *RCap<R>) -> Rights {
    return RCap.rights_of(R, c);
}

// Does the cap permit operation (right id) `b`?
export fn rcap_allows(comptime R: type, c: *RCap<R>, b: u32) -> bool {
    return rights_allows(RCap.rights_of(R, c), b);
}

// Derive a NARROWED sub-capability over the same resource: the child's rights are the
// parent's rights ∩ `keep` — a subset, never a superset. Consumes the parent cap (linear)
// and returns the attenuated child, so a delegation always weakens authority and the
// original is gone. There is intentionally no dual that adds rights: widening would require
// minting a `Rights` from raw, which std/rights forbids outside its module.
export fn rcap_attenuate(comptime R: type, c: RCap<R>, keep: Rights) -> RCap<R> {
    let res: R = RCap.resource_of(R, &c);
    let narrowed: Rights = rights_attenuate(RCap.rights_of(R, &c), keep);
    unsafe { forget_unchecked(c); } // consume the linear parent; the child supersedes it
    return RCap.mint(R, res, narrowed);
}

// Revoke a rights-bearing capability, consuming it (its linear end of life).
export fn rcap_revoke(comptime R: type, c: RCap<R>) -> void {
    unsafe { forget_unchecked(c); } // husk: a capability owns nothing to release
}
