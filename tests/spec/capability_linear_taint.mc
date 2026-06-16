// SPEC: section=31
// SPEC: milestone=opaque-struct
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_PRIVATE_FIELD,E_USE_AFTER_MOVE,E_RESOURCE_LEAK

// Capability LINEARITY + Tainted OPACITY as type laws (hardening K1 / U3).
//
// This mirrors kernel/core/capability's `Cap`/`RCap` and kernel/core/uaccess's `Tainted`
// inline (spec fixtures are parsed standalone, without imports), using concrete `usize`/`u8`
// instantiations so no generic `extern fn` is needed. Two guarantees that were previously NOT
// enforced by the type system are proven structural here:
//
//   1. A capability is `opaque MOVE struct`: opaque alone is field-privacy only, orthogonal
//      to `move`, so without `move` a `Cap` is freely COPYABLE — `cap_revoke` could "consume"
//      one copy while a prior copy stays usable, so revocation does not revoke and the
//      attenuation law breaks. With `move`, a cap has exactly one owner: copying it (using it
//      after it was moved into revoke/attenuate) is E_USE_AFTER_MOVE, and dropping it without
//      consuming is E_RESOURCE_LEAK — revoke/attenuate are now its only linear ends of life.
//
//   2. `Tainted` is `opaque struct`: its `raw` field is private to `impl Tainted`, so outside
//      code CANNOT read `t.raw` (E_PRIVATE_FIELD) to bypass the bound-check validators, nor
//      forge a tainted-looking value with a struct literal. The taint discipline is structural.

// ---- capability: opaque MOVE struct (unforgeable + linear) ----
opaque move struct Cap {
    resource: usize,
}

impl Cap {
    fn mint(resource: usize) -> Cap { return .{ .resource = resource }; }
    fn resource_of(c: *Cap) -> usize { return c.resource; }
}

// The consuming sink stands in for `cap_revoke`/`forget_unchecked` — a cap's single linear end
// of life (a cap owns nothing to release, so revoke just consumes the linear value).
extern fn cap_revoke(c: Cap) -> void;

// ---- rights-bearing capability: opaque MOVE struct ----
opaque struct Rights { bits: u32 }
impl Rights {
    fn grant(bits: u32) -> Rights { return .{ .bits = bits }; }
    fn attenuate(r: Rights, keep: Rights) -> Rights { return .{ .bits = r.bits & keep.bits }; }
}

opaque move struct RCap {
    resource: usize,
    rights: Rights,
}

impl RCap {
    fn mint(resource: usize, rights: Rights) -> RCap { return .{ .resource = resource, .rights = rights }; }
    fn rights_of(c: *RCap) -> Rights { return c.rights; }
}

extern fn rcap_revoke(c: RCap) -> void;

// ---- tainted untrusted scalar: opaque struct (no raw accessor) ----
enum UaccessError { OutOfRange }

opaque struct Tainted {
    raw: u8,
}

impl Tainted {
    fn of(v: u8) -> Tainted { return .{ .raw = v }; }
    fn checked_len(t: Tainted, limit: u8) -> Result<u8, UaccessError> {
        if t.raw > limit { return err(.OutOfRange); }
        return ok(t.raw);
    }
}

// ========================= accepted: the legitimate linear API =========================

// A cap is borrowed (&c) to read its resource, then consumed exactly once by revoke.
fn accept_cap_borrow_then_revoke() -> usize {
    let c: Cap = Cap.mint(0x1000_0000);
    let base: usize = Cap.resource_of(&c); // borrow, does not consume
    cap_revoke(c);                          // single linear end of life
    return base;
}

// Attenuation borrows the parent to read its rights, then consumes it; the child supersedes it.
fn accept_rcap_attenuate_consumes_parent() -> void {
    let parent: RCap = RCap.mint(0x1000_0000, Rights.grant(0xF));
    let narrowed: Rights = Rights.attenuate(RCap.rights_of(&parent), Rights.grant(0x3));
    rcap_revoke(parent);                    // parent consumed (forget_unchecked in the real code)
    let child: RCap = RCap.mint(0x1000_0000, narrowed);
    rcap_revoke(child);
}

// A tainted value goes through the validator (which names .raw inside its impl) — the only
// way to extract a usable scalar.
fn accept_tainted_checked() -> Result<u8, UaccessError> {
    let t: Tainted = Tainted.of(7);
    return Tainted.checked_len(t, 64);
}

// ===================== rejected: forging / copying / raw extraction =====================

// FORGING a cap by struct literal outside its impl manufactures authority.
fn reject_forge_cap() -> Cap {
    // EXPECT_ERROR: E_PRIVATE_FIELD
    return .{ .resource = 0x1000_0000 };
}

// COPYING a cap: using it after it was moved into revoke. A non-`move` cap would allow this
// (the copy stays usable); `move` makes the second use E_USE_AFTER_MOVE — so a "revoked" cap
// genuinely cannot be used again.
fn reject_copy_cap_after_revoke() -> usize {
    let c: Cap = Cap.mint(0x1000_0000);
    cap_revoke(c);                          // c moved (consumed) here
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return Cap.resource_of(&c);             // stale use of the revoked cap
}

// Binding a cap to a second name is a copy of a linear value — rejected.
fn reject_alias_cap() -> void {
    let c: Cap = Cap.mint(0x1000_0000);
    let d: Cap = c;                         // c moved into d
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    cap_revoke(c);                          // c already moved
    cap_revoke(d);
}

// A minted cap that is never consumed leaks — there is no implicit drop for a linear cap.
fn reject_leak_cap() -> usize {
    // EXPECT_ERROR: E_RESOURCE_LEAK
    let c: Cap = Cap.mint(0x1000_0000);
    return 0;
}

// Using an RCap after it was moved into attenuation/revoke: the parent is gone.
fn reject_rcap_use_after_revoke() -> void {
    let parent: RCap = RCap.mint(0x1000_0000, Rights.grant(0xF));
    rcap_revoke(parent);                    // parent consumed
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let r: Rights = RCap.rights_of(&parent);
    rcap_revoke(RCap.mint(0, r));
}

// READING Tainted.raw outside impl Tainted bypasses the validators (the U3 hole that was
// convention-only before opacity).
fn reject_read_tainted_raw(t: Tainted) -> u8 {
    // EXPECT_ERROR: E_PRIVATE_FIELD
    return t.raw;
}

// FORGING a Tainted by struct literal (to set .raw directly) is rejected.
fn reject_forge_tainted() -> Tainted {
    // EXPECT_ERROR: E_PRIVATE_FIELD
    return .{ .raw = 255 };
}
