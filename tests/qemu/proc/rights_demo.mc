// K1 runtime demo: the unforgeable + monotonic (narrow-only) `Rights` discipline and the
// rights-bearing capability `RCap`. This exercises the RUNTIME behaviour of the type-law
// machinery; the static forge/widen rejection is pinned by tests/spec/rights_monotonic.mc
// (an opaque-struct field-privacy fixture). Together: forging/widening is a compile error,
// and the operations that ARE allowed (attenuation) only ever narrow authority.

import "std/rights.mc";
import "kernel/core/capability.mc";

export fn rights_run() -> u32 {
    var pass: u32 = 1;

    // Privileged root mint: full authority over rights {0,1,2,3}.
    let parent: Rights = rights_grant(0xF);
    if !rights_allows(parent, 0) { pass = 0; }
    if !rights_allows(parent, 3) { pass = 0; }

    // Attenuation NARROWS: parent {0,1,2,3} ∩ keep {0,1} = child {0,1}.
    let child: Rights = rights_attenuate(parent, rights_grant(0x3));
    if !rights_allows(child, 0) { pass = 0; }
    if !rights_allows(child, 1) { pass = 0; }
    if rights_allows(child, 2) { pass = 0; }   // dropped
    if rights_allows(child, 3) { pass = 0; }   // dropped

    // Parent ⊇ child law: every right the child holds the parent also holds.
    if !rights_subset_of(child, parent) { pass = 0; }
    // And the reverse is false here — the parent is strictly stronger.
    if rights_subset_of(parent, child) { pass = 0; }

    // Attenuation cannot REGAIN a dropped right: child {0,1} ∩ {0,1,2,3} stays {0,1}.
    // `keep` can only remove; bits the value already lacks can never be restored.
    let grandchild: Rights = rights_attenuate_mask(child, 0xF);
    if rights_allows(grandchild, 2) { pass = 0; } // still gone
    if rights_allows(grandchild, 3) { pass = 0; } // still gone
    if !rights_subset_of(grandchild, child) { pass = 0; }  // ⊆ its own parent
    if !rights_subset_of(grandchild, parent) { pass = 0; } // transitively ⊆ the root

    // `rights_without` drops a single right (pure attenuation).
    let dropped: Rights = rights_without(child, 0);
    if rights_allows(dropped, 0) { pass = 0; }
    if !rights_allows(dropped, 1) { pass = 0; }
    if !rights_subset_of(dropped, child) { pass = 0; }

    // The empty set holds nothing and is a subset of everything.
    let nada: Rights = rights_none();
    if !rights_is_empty(nada) { pass = 0; }
    if !rights_subset_of(nada, parent) { pass = 0; }

    // ----- rights-bearing capability: narrow-only delegation over a resource -----
    // Mint a cap over a fake MMIO base with rights {0,1,2,3}.
    let cap: RCap<usize> = rcap_mint(usize, 0x1000_0000, rights_grant(0xF));
    if !rcap_allows(usize, &cap, 2) { pass = 0; }
    let cap_rights: Rights = rcap_rights(usize, &cap);

    // Delegate a NARROWED sub-cap: rights ∩ {0,1} = {0,1}. Consumes the parent cap.
    let sub: RCap<usize> = rcap_attenuate(usize, cap, rights_grant(0x3));
    if !rcap_allows(usize, &sub, 0) { pass = 0; }
    if rcap_allows(usize, &sub, 2) { pass = 0; }  // narrowed away
    // The resource is unchanged by attenuation; only the rights shrank.
    if rcap_resource(usize, &sub) != 0x1000_0000 { pass = 0; }
    // The sub-cap's rights ⊆ the original cap's rights (parent ⊇ child).
    if !rights_subset_of(rcap_rights(usize, &sub), cap_rights) { pass = 0; }

    rcap_revoke(usize, sub); // consume the linear cap

    return pass;
}
