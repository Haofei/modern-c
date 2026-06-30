// kernel/core/ledger — a UNIFIED, overflow-safe resource ledger.
//
// Resource accounting in this kernel is today scattered across per-dimension budgets, each
// hand-rolling its own {used, limit} counters and over-limit check: process memory quotas
// (kernel/core/process.mc / kernel/lib/resacct.mc), the net broker's byte budget
// (kernel/net/net_broker.mc), IPC message ledgers (kernel/core/proc_ipc.mc), the MCP tool budget
// (kernel/agent/mcp.mc), policy quotas (kernel/core/policy.mc), and scheduler accounting
// (kernel/core/proc_sched.mc). Every one repeats the same fragile charge/release arithmetic.
//
// This module is the ONE ledger they can all share: a single `Ledger` carries a {used, limit}
// pair per `Resource` dimension, with consistent overflow-safe charge/release semantics and a
// typed `LedgerError`. A caller charges against a dimension when it reserves a resource and
// releases when it frees one; the ledger refuses (fail-closed, no partial charge) any charge that
// would exceed the dimension's limit, computing the headroom as `limit - used` so the naive
// `used + amount` sum is NEVER formed and can never overflow/trap.
//
// FOLLOW-UP (out of scope here): wiring the existing scattered call-sites
// (process/net_broker/proc_ipc/mcp/policy/proc_sched budgets) onto this ledger. This task only
// delivers the reusable, proven-correct unified primitive + its gate.
//
// CONVENTION — `limit == 0` means UNLIMITED (no ceiling). A fresh `Ledger` is all-zero, so every
// dimension starts unlimited; a caller opts a dimension into enforcement with `ledger_set_limit`.
// Even an unlimited dimension is guarded against a `used` counter overflow (saturating the headroom
// at u64 max), so a charge can never wrap the counter.

const LEDGER_DIMS: usize = 6;             // number of Resource variants
const LEDGER_U64_MAX: u64 = 0xFFFF_FFFF_FFFF_FFFF;

// The fixed set of accountable resource dimensions, covering the scattered budgets above.
// Ordinals (0..LEDGER_DIMS) index the per-dimension entry array.
enum Resource {
    Memory,      // bytes/pages of process memory (process.mc / resacct.mc)
    DmaBytes,    // bytes pinned for device DMA (virtio drivers)
    IpcMessages, // in-flight IPC messages (proc_ipc.mc)
    BlockIo,     // block-device I/O operations / bytes (block layer)
    NetBytes,    // network bytes sent/received (net_broker.mc)
    FileHandles, // open file/tool handles (mcp.mc / fs)
}

// Why a charge or release was refused.
enum LedgerError {
    OverLimit, // the charge would exceed the dimension's limit (or overflow `used`) — nothing reserved
    Underflow, // the release exceeds what is currently charged — nothing released
}

// One dimension's accounting: `used` units reserved, `limit` ceiling (0 = unlimited).
struct LedgerEntry {
    used: u64,
    limit: u64,
}

struct Ledger {
    entries: [LEDGER_DIMS]LedgerEntry,
}

// Stable ordinal for a Resource (its index into `entries`).
fn res_index(res: Resource) -> usize {
    switch res {
        .Memory => { return 0; }
        .DmaBytes => { return 1; }
        .IpcMessages => { return 2; }
        .BlockIo => { return 3; }
        .NetBytes => { return 4; }
        .FileHandles => { return 5; }
    }
}

// Reset every dimension to used=0, limit=0 (unlimited). The starting state for a fresh account.
export fn ledger_init(l: *mut Ledger) -> void {
    var i: usize = 0;
    while i < LEDGER_DIMS {
        l.entries[i].used = 0;
        l.entries[i].limit = 0;
        i = i + 1;
    }
}

// Set the hard ceiling for one dimension (0 = unlimited). Does not touch `used`; a limit set below
// the current `used` simply means every further charge fails until enough is released.
export fn ledger_set_limit(l: *mut Ledger, res: Resource, limit: u64) -> void {
    l.entries[res_index(res)].limit = limit;
}

// Reserve `amount` units against `res`. All-or-nothing (fail closed): on success `used += amount`
// and `ok(true)` is returned; on failure `used` is left untouched and `err(.OverLimit)` is
// returned, so the caller can treat it as a clean no-op.
//
// OVERFLOW-SAFE: the headroom is computed as `limit - used` (a subtraction that cannot overflow
// because the invariant `used <= limit` holds whenever a limit is set), and `amount` is compared
// against THAT. The naive `used + amount` sum — which would overflow a u64 and, under checked
// arithmetic, TRAP — is never formed. For an unlimited dimension the headroom is `U64_MAX - used`,
// so even an unbounded counter cannot wrap.
export fn ledger_charge(l: *mut Ledger, res: Resource, amount: u64) -> Result<bool, LedgerError> {
    let i: usize = res_index(res);
    let used: u64 = l.entries[i].used;
    let limit: u64 = l.entries[i].limit;

    var headroom: u64 = 0;
    if limit == 0 {
        headroom = LEDGER_U64_MAX - used; // unlimited: only the u64 counter bounds us
    } else {
        if used > limit {
            // a limit was lowered below `used`; no headroom (and avoid an underflowing subtraction)
            headroom = 0;
        } else {
            headroom = limit - used;
        }
    }

    if amount > headroom {
        return err(.OverLimit); // would exceed the ceiling (or wrap `used`) — nothing reserved
    }
    l.entries[i].used = used + amount; // safe: amount <= headroom, so this cannot overflow
    return ok(true);
}

// Release `amount` units previously charged to `res`. Refuses `err(.Underflow)` if `amount`
// exceeds what is currently reserved, leaving `used` unchanged; otherwise `used -= amount`.
export fn ledger_release(l: *mut Ledger, res: Resource, amount: u64) -> Result<bool, LedgerError> {
    let i: usize = res_index(res);
    let used: u64 = l.entries[i].used;
    if amount > used {
        return err(.Underflow); // releasing more than charged — nothing released
    }
    l.entries[i].used = used - amount;
    return ok(true);
}

// Units currently reserved against `res`.
export fn ledger_used(l: *Ledger, res: Resource) -> u64 {
    return l.entries[res_index(res)].used;
}

// The hard ceiling for `res` (0 = unlimited).
export fn ledger_limit(l: *Ledger, res: Resource) -> u64 {
    return l.entries[res_index(res)].limit;
}

// Units still chargeable against `res` before hitting its limit, computed overflow-safe as
// `limit - used` and saturating at 0. An unlimited dimension reports `U64_MAX - used`.
export fn ledger_available(l: *Ledger, res: Resource) -> u64 {
    let i: usize = res_index(res);
    let used: u64 = l.entries[i].used;
    let limit: u64 = l.entries[i].limit;
    if limit == 0 {
        return LEDGER_U64_MAX - used; // unlimited
    }
    if used >= limit {
        return 0;
    }
    return limit - used;
}
