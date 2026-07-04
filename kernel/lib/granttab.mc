// kernel/lib/granttab — owner-tracked memory grants, so the kernel can revoke everything a
// process shared when it dies. Builds on std/grant (bounded, generation-revocable regions);
// this adds an owner pid per grant and revoke-by-owner, the hook the process-death path calls
// so no server keeps writing into a dead client's memory through a stale GrantRef.

import "std/grant.mc";
import "std/addr.mc";
import "std/math.mc";

const GRANTTAB_MAX: usize = 8;

pub enum GrantTabError {
    Full,        // no free grant slot
    BadId,       // no grant with that id
    Revoked,     // the grant was revoked (e.g. the owner died) since this ref was issued
    OutOfBounds, // the requested copy falls outside the granted region (or a forged ref)
}

// Sentinel for "no parent": an owner-rooted grant (created via grant_table_make) is not
// delegated from any other grant. A real parent is a table index in [0, GRANTTAB_MAX).
const GRANT_NO_PARENT: usize = GRANTTAB_MAX;

struct GrantSlot {
    grant: Grant,
    // The owner is an endpoint identity (slot + generation), not a bare pid: process slots
    // are reused, so a bare pid could let a new incarnation in a recycled slot revoke (or be
    // matched against) a dead owner's grants. Matching the generation too means a reused slot
    // is a different owner.
    owner_slot: u32,
    owner_gen: u32,
    // Delegation parent link. A grant created by grant_table_delegate records the table id of
    // the grant it was re-shared from; an owner-rooted grant stores GRANT_NO_PARENT. We also
    // pin the parent's generation at delegation time (parent_gen) so the link is only honoured
    // while the parent is the *same* grant — if the parent slot was revoked and reused, the
    // generations diverge and this stale child is treated as already orphaned (fail closed).
    parent: usize,
    parent_gen: u32,
    present: bool,
}

pub struct GrantTable {
    slots: [GRANTTAB_MAX]GrantSlot,
    count: usize,
}

pub fn grant_table_init(tab: *mut GrantTable) -> void {
    var i: usize = 0;
    while i < GRANTTAB_MAX {
        tab.slots[i].present = false;
        // Seed each slot's generation so the first grant on it starts at 1 and every reuse
        // monotonically advances — a slot's generation is never reset, so a stale ref can't
        // be revived by a later grant on the same slot.
        tab.slots[i].grant = grant_make_gen(pa(0), 0, 0);
        tab.slots[i].parent = GRANT_NO_PARENT;
        tab.slots[i].parent_gen = 0;
        i = i + 1;
    }
    tab.count = 0;
}

pub fn grant_table_count(tab: *mut GrantTable) -> usize {
    return tab.count;
}

// Owner endpoint (owner_slot, owner_gen) grants access to [base, base+len). Returns the
// grant id, or Full.
pub fn grant_table_make(tab: *mut GrantTable, owner_slot: u32, owner_gen: u32, base: PAddr, len: usize) -> Result<usize, GrantTabError> {
    var i: usize = 0;
    while i < GRANTTAB_MAX {
        if !tab.slots[i].present {
            // Continue the slot's generation (it is never reset), so an outstanding ref to a
            // previous grant on this slot — even with matching base/len — cannot validate
            // against the new grant. grant_revoke also advanced it when the old grant died.
            let next_gen: u32 = tab.slots[i].grant.gen + 1; // checked: fail closed on exhaustion
            tab.slots[i].grant = grant_make_gen(base, len, next_gen);
            tab.slots[i].owner_slot = owner_slot;
            tab.slots[i].owner_gen = owner_gen;
            tab.slots[i].parent = GRANT_NO_PARENT; // owner-rooted: not delegated from anything
            tab.slots[i].parent_gen = 0;
            tab.slots[i].present = true;
            tab.count = tab.count + 1;
            return ok(i);
        }
        i = i + 1;
    }
    return err(.Full);
}

// Issue a copyable reference to grant `id` (to carry over IPC to a server), or BadId.
pub fn grant_table_ref(tab: *mut GrantTable, id: usize) -> Result<GrantRef, GrantTabError> {
    if id >= GRANTTAB_MAX {
        return err(.BadId);
    }
    if !tab.slots[id].present {
        return err(.BadId);
    }
    let p: *GrantSlot = &tab.slots[id];
    return ok(grant_ref(&p.grant));
}

// Validate a ref against the live grant: ok if still valid, Revoked if the grant was revoked
// (e.g. its owner died), BadId if the grant is gone.
pub fn grant_table_open(tab: *mut GrantTable, id: usize, r: GrantRef) -> Result<bool, GrantTabError> {
    if id >= GRANTTAB_MAX {
        return err(.BadId);
    }
    if !tab.slots[id].present {
        return err(.BadId);
    }
    let p: *GrantSlot = &tab.slots[id];
    switch grant_open(&p.grant, r) {
        ok(b) => {
            return ok(true);
        }
        err(e) => {
            return err(.Revoked); // gen mismatch -> revoked since the ref was issued
        }
    }
}

// Copy `n` bytes out of grant `id`'s region (at offset `off`) to `dst`, validating the
// (untrusted) ref against the live grant in the table. Bounds come from the stored grant, so a
// forged/widened ref or a revoked grant fails closed rather than reaching the client's memory.
pub fn grant_table_copy_out(tab: *mut GrantTable, id: usize, r: GrantRef, off: usize, dst: PAddr, n: usize) -> Result<bool, GrantTabError> {
    if id >= GRANTTAB_MAX {
        return err(.BadId);
    }
    if !tab.slots[id].present {
        return err(.BadId);
    }
    let p: *GrantSlot = &tab.slots[id];
    // Distinguish the two failure modes up front so the caller learns why it was rejected:
    // a generation mismatch means the grant was revoked (e.g. its owner died) since the ref
    // was issued; anything grant_copy_out rejects after that is a forged/widened ref or an
    // out-of-range length.
    if r.gen != p.grant.gen {
        return err(.Revoked);
    }
    switch grant_copy_out(&p.grant, r, off, dst, n) {
        ok(b) => {
            return ok(true);
        }
        err(e) => {
            return err(.OutOfBounds); // forged/widened ref or out-of-range copy
        }
    }
}

// Revoke every grant owned by the endpoint (owner_slot, owner_gen) — the process-death
// hook. Returns how many were revoked. Each revoked grant's slot is reclaimed (gen bumped,
// `present` cleared, `count` decremented), so a dead owner's grants do not occupy table
// slots forever. Matching the generation as well as the slot means a reused slot (a new
// incarnation) does not inherit or revoke the previous owner's grants.
pub fn grant_table_revoke_owner(tab: *mut GrantTable, owner_slot: u32, owner_gen: u32) -> usize {
    var revoked: usize = 0;
    var i: usize = 0;
    while i < GRANTTAB_MAX {
        if tab.slots[i].present {
            if tab.slots[i].owner_slot == owner_slot {
                if tab.slots[i].owner_gen == owner_gen {
                    grant_revoke(&tab.slots[i].grant); // invalidate outstanding refs
                    tab.slots[i].present = false;       // reclaim the dead owner's slot
                    tab.count = tab.count - 1;
                    revoked = revoked + 1;
                }
            }
        }
        i = i + 1;
    }
    return revoked;
}

// True iff [base, base+len) is contained within [pbase, pbase+plen) — the attenuation rule for
// delegation: a child grant can only ever cover a sub-region of its parent, never widen it.
// Computed on raw address values so an empty child (len 0) inside the parent is still accepted.
fn grant_within(pbase: PAddr, plen: usize, base: PAddr, len: usize) -> bool {
    let pstart: usize = pa_value(pbase);
    let pend: usize = pstart + plen;     // parent grants come from real allocations; no overflow
    let cstart: usize = pa_value(base);
    let cend: usize = cstart + len;
    if cstart < pstart { return false; }
    if cend > pend { return false; }
    return true;
}

// Delegation: recipient re-shares grant `parent_id` (or a sub-region of it) onward to a new
// owner endpoint, producing a *child* grant linked to the parent. Attenuation is enforced —
// the child's [base, len) must be ⊆ the parent's region (a delegation that tries to widen
// beyond what it was given is rejected OutOfBounds). The child records the parent's id and
// current generation, so revoking the parent (or anything above it) cascades down (see
// grant_table_revoke_cascade). Returns the child's id, or Full/BadId/OutOfBounds.
pub fn grant_table_delegate(tab: *mut GrantTable, parent_id: usize, new_owner_slot: u32, new_owner_gen: u32, base: PAddr, len: usize) -> Result<usize, GrantTabError> {
    if parent_id >= GRANTTAB_MAX {
        return err(.BadId);
    }
    if !tab.slots[parent_id].present {
        return err(.BadId);
    }
    let pgen: u32 = tab.slots[parent_id].grant.gen;
    let pbase: PAddr = tab.slots[parent_id].grant.base;
    let plen: usize = tab.slots[parent_id].grant.len;
    // Attenuation: the delegated region must not exceed the parent's. Reject up front.
    if !grant_within(pbase, plen, base, len) {
        return err(.OutOfBounds);
    }
    var i: usize = 0;
    while i < GRANTTAB_MAX {
        if !tab.slots[i].present {
            let next_gen: u32 = tab.slots[i].grant.gen + 1; // checked: fail closed on exhaustion
            tab.slots[i].grant = grant_make_gen(base, len, next_gen);
            tab.slots[i].owner_slot = new_owner_slot;
            tab.slots[i].owner_gen = new_owner_gen;
            tab.slots[i].parent = parent_id;  // link to the grant this authority descends from
            tab.slots[i].parent_gen = pgen;   // pin the parent's identity at delegation time
            tab.slots[i].present = true;
            tab.count = tab.count + 1;
            return ok(i);
        }
        i = i + 1;
    }
    return err(.Full);
}

// Revoke grant `id` and the entire delegation subtree rooted at it: every grant whose parent
// chain reaches `id` is invalidated (its generation bumped, so outstanding refs fail closed)
// and its slot reclaimed. Authority handed down a chain is reclaimable from any node above it.
//
// Bounded, no recursion: the table is fixed (GRANTTAB_MAX slots) and a revoke only ever
// removes slots, so we sweep the whole table at most GRANTTAB_MAX times. Each pass revokes any
// still-present grant whose live parent was revoked on an earlier pass; once a pass revokes
// nothing new we are done. Worst case (a linear chain) needs one pass per link — O(N^2) over a
// table of 8, with a hard outer cap so it always terminates.
//
// Returns the number of grants revoked (the root plus all transitive descendants).
pub fn grant_table_revoke_cascade(tab: *mut GrantTable, id: usize) -> Result<usize, GrantTabError> {
    if id >= GRANTTAB_MAX {
        return err(.BadId);
    }
    if !tab.slots[id].present {
        return err(.BadId);
    }
    var revoked: usize = 0;
    // Revoke the root first.
    grant_revoke(&tab.slots[id].grant);
    tab.slots[id].present = false;
    tab.count = tab.count - 1;
    revoked = revoked + 1;

    // Iteratively orphan-and-revoke descendants. A child is revoked once the grant it was
    // delegated from is no longer present (revoked) or has been replaced by a newer grant on
    // the same slot (generation moved past the pinned parent_gen). Each pass picks up children
    // whose parent was revoked on the previous pass, so the whole subtree drains in at most
    // GRANTTAB_MAX passes.
    var pass: usize = 0;
    while pass < GRANTTAB_MAX {
        var changed: bool = false;
        var i: usize = 0;
        while i < GRANTTAB_MAX {
            if tab.slots[i].present {
                let p: usize = tab.slots[i].parent;
                if p < GRANTTAB_MAX {
                    // The parent is gone (revoked) when its slot is no longer the same grant
                    // this child was delegated from: either not present, or its generation has
                    // moved past the pinned parent_gen. That means the parent was revoked —
                    // cascade the revocation to this child.
                    var orphaned: bool = false;
                    if !tab.slots[p].present {
                        orphaned = true;
                    } else if tab.slots[p].grant.gen != tab.slots[i].parent_gen {
                        orphaned = true;
                    }
                    if orphaned {
                        grant_revoke(&tab.slots[i].grant);
                        tab.slots[i].present = false;
                        tab.count = tab.count - 1;
                        revoked = revoked + 1;
                        changed = true;
                    }
                }
            }
            i = i + 1;
        }
        if !changed {
            return ok(revoked);
        }
        pass = pass + 1;
    }
    return ok(revoked);
}
