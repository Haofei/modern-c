// tests/support/capability — capability-style least privilege fixture made
// explicit with MC's linear types. A `Cap<R>` is an *unforgeable, linear* grant of
// access to a resource R (e.g. a device's MMIO base, an IRQ line, a memory region):
//
//   - unforgeable: `Cap` is a `linear opaque struct` (section 31), so its `resource` field is
//     private to this module — outside code CANNOT construct one with a struct literal
//     `.{ .resource = X }` (that is `E_PRIVATE_FIELD`). `cap_mint` is the only public
//     constructor, and it requires the explicit `BootAuthority` root token;
//   - linear: a cap has exactly one owner and cannot be copied, so a process
//     without the cap simply cannot name the resource. Transfer is explicit.
//
// This is least privilege enforced by the type system: code that doesn't hold
// `Cap<Mmio>` can't even express the access — and cannot forge one.
//
// `RCap<R>` (below) extends a cap with an UNFORGEABLE, MONOTONIC rights set (std/rights):
// the same resource handle, plus an attenuable `Rights`. Sub-grants can only NARROW the
// rights (never widen) — the attenuated-subgrant property as a type law.

import "std/rights.mc";

pub linear opaque struct BootAuthority {
    marker: u32,
}

impl BootAuthority {
    fn mint() -> BootAuthority {
        return .{ .marker = 0x424f4f54 };
    }
    fn require(auth: *BootAuthority) -> void {
        if auth.marker == 0 {
        }
    }
}

// Privileged root creation seam. MC currently has unsafe blocks but not unsafe
// function declarations, so the source audit gate restricts this unchecked root
// to approved boot authority sites. Possessing the opaque linear token is required to
// mint new caps; non-root holders can only use, attenuate, transfer, or revoke
// capabilities they already received.
pub fn boot_authority_unchecked() -> BootAuthority {
    return BootAuthority.mint();
}

pub fn boot_authority_revoke(auth: BootAuthority) -> void {
    unsafe { forget_unchecked(auth); }
}

pub linear opaque struct Cap<R> {
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

// Grant a capability over `resource` (the privileged setup-time primitive). The explicit
// authority parameter prevents ordinary imports of this module from being ambient mint roots.
pub fn cap_mint(comptime R: type, auth: *BootAuthority, resource: R) -> Cap<R> {
    BootAuthority.require(auth);
    return Cap.mint(R, resource);
}

// Use the capability: borrow it to read the granted resource. Does not consume it.
pub fn cap_resource(comptime R: type, c: *Cap<R>) -> R {
    return Cap.resource_of(R, c);
}

// Revoke the capability, consuming it (its linear end of life).
pub fn cap_revoke(comptime R: type, c: Cap<R>) -> void {
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

pub linear opaque struct RCap<R> {
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

// Mint a rights-bearing capability (privileged setup-time primitive).
pub fn rcap_mint(comptime R: type, auth: *BootAuthority, resource: R, rights: Rights) -> RCap<R> {
    BootAuthority.require(auth);
    return RCap.mint(R, resource, rights);
}

// Read the resource a rights-bearing cap grants. Borrows; does not consume.
pub fn rcap_resource(comptime R: type, c: *RCap<R>) -> R {
    return RCap.resource_of(R, c);
}

// Read the rights a cap carries. Borrows; does not consume.
pub fn rcap_rights(comptime R: type, c: *RCap<R>) -> Rights {
    return RCap.rights_of(R, c);
}

// Does the cap permit operation (right id) `b`?
pub fn rcap_allows(comptime R: type, c: *RCap<R>, b: u32) -> bool {
    return rights_allows(RCap.rights_of(R, c), b);
}

// Derive a NARROWED sub-capability over the same resource: the child's rights are the
// parent's rights ∩ `keep` — a subset, never a superset. Consumes the parent cap (linear)
// and returns the attenuated child, so a delegation always weakens authority and the
// original is gone. There is intentionally no dual that adds rights: widening would require
// minting a `Rights` from raw, which std/rights forbids outside its module.
pub fn rcap_attenuate(comptime R: type, c: RCap<R>, keep: Rights) -> RCap<R> {
    let res: R = RCap.resource_of(R, &c);
    let narrowed: Rights = rights_attenuate(RCap.rights_of(R, &c), keep);
    unsafe { forget_unchecked(c); } // consume the linear parent; the child supersedes it
    return RCap.mint(R, res, narrowed);
}

// Revoke a rights-bearing capability, consuming it (its linear end of life).
pub fn rcap_revoke(comptime R: type, c: RCap<R>) -> void {
    unsafe { forget_unchecked(c); } // husk: a capability owns nothing to release
}
