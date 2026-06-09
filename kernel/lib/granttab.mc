// kernel/lib/granttab — owner-tracked memory grants, so the kernel can revoke everything a
// process shared when it dies. Builds on std/grant (bounded, generation-revocable regions);
// this adds an owner pid per grant and revoke-by-owner, the hook the process-death path calls
// so no server keeps writing into a dead client's memory through a stale GrantRef.

import "std/grant.mc";
import "std/addr.mc";

const GRANTTAB_MAX: usize = 8;

enum GrantTabError {
    Full,    // no free grant slot
    BadId,   // no grant with that id
    Revoked, // the grant was revoked (e.g. the owner died) since this ref was issued
}

struct GrantSlot {
    grant: Grant,
    owner: u32, // the pid that owns (and may revoke) this grant
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
        i = i + 1;
    }
    tab.count = 0;
}

export fn grant_table_count(tab: *mut GrantTable) -> usize {
    return tab.count;
}

// Owner `owner` grants access to [base, base+len). Returns the grant id, or Full.
export fn grant_table_make(tab: *mut GrantTable, owner: u32, base: PAddr, len: usize) -> Result<usize, GrantTabError> {
    var i: usize = 0;
    while i < GRANTTAB_MAX {
        if !tab.slots[i].present {
            tab.slots[i].grant = grant_make(base, len);
            tab.slots[i].owner = owner;
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

// Revoke one grant (outstanding refs become stale), or BadId.
export fn grant_table_revoke(tab: *mut GrantTable, id: usize) -> Result<bool, GrantTabError> {
    if id >= GRANTTAB_MAX {
        return err(.BadId);
    }
    if !tab.slots[id].present {
        return err(.BadId);
    }
    grant_revoke(&tab.slots[id].grant);
    return ok(true);
}

// Revoke every grant owned by `owner` — the process-death hook. Returns how many were revoked.
export fn grant_table_revoke_owner(tab: *mut GrantTable, owner: u32) -> usize {
    var revoked: usize = 0;
    var i: usize = 0;
    while i < GRANTTAB_MAX {
        if tab.slots[i].present {
            if tab.slots[i].owner == owner {
                grant_revoke(&tab.slots[i].grant);
                revoked = revoked + 1;
            }
        }
        i = i + 1;
    }
    return revoked;
}
