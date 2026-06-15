// kernel/lib/granttab — owner-tracked memory grants, so the kernel can revoke everything a
// process shared when it dies. Builds on std/grant (bounded, generation-revocable regions);
// this adds an owner pid per grant and revoke-by-owner, the hook the process-death path calls
// so no server keeps writing into a dead client's memory through a stale GrantRef.

import "std/grant.mc";
import "std/addr.mc";
import "std/math.mc";

const GRANTTAB_MAX: usize = 8;

enum GrantTabError {
    Full,        // no free grant slot
    BadId,       // no grant with that id
    Revoked,     // the grant was revoked (e.g. the owner died) since this ref was issued
    OutOfBounds, // the requested copy falls outside the granted region (or a forged ref)
}

struct GrantSlot {
    grant: Grant,
    // The owner is an endpoint identity (slot + generation), not a bare pid: process slots
    // are reused, so a bare pid could let a new incarnation in a recycled slot revoke (or be
    // matched against) a dead owner's grants. Matching the generation too means a reused slot
    // is a different owner.
    owner_slot: u32,
    owner_gen: u32,
    present: bool,
}

struct GrantTable {
    slots: [GRANTTAB_MAX]GrantSlot,
    count: usize,
}

export fn grant_table_init(tab: *mut GrantTable) -> void {
    var i: usize = 0;
    while i < GRANTTAB_MAX {
        tab.slots[i].present = false;
        // Seed each slot's generation so the first grant on it starts at 1 and every reuse
        // monotonically advances — a slot's generation is never reset, so a stale ref can't
        // be revived by a later grant on the same slot.
        tab.slots[i].grant = grant_make_gen(pa(0), 0, 0);
        i = i + 1;
    }
    tab.count = 0;
}

export fn grant_table_count(tab: *mut GrantTable) -> usize {
    return tab.count;
}

// Owner endpoint (owner_slot, owner_gen) grants access to [base, base+len). Returns the
// grant id, or Full.
export fn grant_table_make(tab: *mut GrantTable, owner_slot: u32, owner_gen: u32, base: PAddr, len: usize) -> Result<usize, GrantTabError> {
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
            tab.slots[i].present = true;
            tab.count = tab.count + 1;
            return ok(i);
        }
        i = i + 1;
    }
    return err(.Full);
}

// Issue a copyable reference to grant `id` (to carry over IPC to a server), or BadId.
export fn grant_table_ref(tab: *mut GrantTable, id: usize) -> Result<GrantRef, GrantTabError> {
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
export fn grant_table_open(tab: *mut GrantTable, id: usize, r: GrantRef) -> Result<bool, GrantTabError> {
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
export fn grant_table_copy_out(tab: *mut GrantTable, id: usize, r: GrantRef, off: usize, dst: PAddr, n: usize) -> Result<bool, GrantTabError> {
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
export fn grant_table_revoke_owner(tab: *mut GrantTable, owner_slot: u32, owner_gen: u32) -> usize {
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
