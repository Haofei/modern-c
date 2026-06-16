// kernel/lib/resacct — a `ResourceAccount`: a quota-enforced usage counter. A subsystem (a
// memory pool, a per-process page budget, an mbuf allowance, ...) charges and uncharges units
// against a fixed `limit`; the account tracks `used` and refuses any charge that would exceed
// the limit. The primitive accounting building block every resource allocator hand-rolls.
//
// CONTRACT — fail closed, no partial charge. `resacct_charge(n)` either reserves ALL n units
// (used += n) or none at all: if the charge would push `used` past `limit` (or overflow a
// usize), `used` is left untouched and `OverQuota` is returned. A caller can therefore treat a
// failed charge as a no-op and retry / back off without first un-doing a partial reservation.
// `resacct_uncharge(n)` saturates at zero, so releasing more than was charged can never
// underflow the counter below its floor. Pure unit: no allocation, no imports.

enum MemError {
    OverQuota, // the charge would exceed `limit` (or overflow usize) — nothing was reserved
}

struct ResourceAccount {
    used: usize,  // units currently reserved
    limit: usize, // hard ceiling: used never exceeds this
}

export fn resacct_init(a: *mut ResourceAccount, limit: usize) -> void {
    a.used = 0;
    a.limit = limit;
}

// Reserve `n` units. All-or-nothing: on success `used += n` and the new total is returned; on
// failure (`used + n` exceeds `limit`, or the addition would overflow a usize) `used` is left
// unchanged and `OverQuota` is returned. The overflow guard (`a.used + n < a.used`) catches the
// wraparound case where a huge `n` would otherwise compute a small, deceptively-in-budget sum.
export fn resacct_charge(a: *mut ResourceAccount, n: usize) -> Result<usize, MemError> {
    let sum: usize = a.used + n;
    if sum < a.used {
        return err(.OverQuota); // usize overflow — nothing reserved
    }
    if sum > a.limit {
        return err(.OverQuota); // over the ceiling — nothing reserved
    }
    a.used = sum;
    return ok(a.used);
}

// Release up to `n` units, saturating at zero so an over-release can never underflow `used`.
export fn resacct_uncharge(a: *mut ResourceAccount, n: usize) -> void {
    if n > a.used {
        a.used = 0;
    } else {
        a.used = a.used - n;
    }
}

// Units still chargeable before hitting the limit; 0 if somehow at/over the ceiling.
export fn resacct_available(a: *mut ResourceAccount) -> usize {
    if a.used >= a.limit {
        return 0;
    }
    return a.limit - a.used;
}

// Units currently reserved.
export fn resacct_used(a: *mut ResourceAccount) -> usize {
    return a.used;
}

// Release everything: drop `used` back to zero (the limit is untouched).
export fn resacct_reset(a: *mut ResourceAccount) -> void {
    a.used = 0;
}
