// UNIFIED RESOURCE LEDGER — correctness + overflow-safety demo (driver logic).
//
// Exercises kernel/core/ledger.mc: the one ledger that replaces the per-dimension {used,limit}
// budgets scattered across process/net_broker/proc_ipc/mcp/policy/proc_sched. `ledger_run`
// returns 1 only if every property below holds; the M-mode runtime (ledger_runtime.mc) prints
// LEDGER-OK / UNIFIED-LEDGER-OK off that pass code.
//
// Properties asserted:
//   1. a charge within the limit succeeds and used/available update correctly;
//   2. a charge that would exceed the limit returns err(OverLimit) and does NOT mutate used;
//   3. the OVERFLOW EDGE — with the limit near u64 max and used near it, a charge whose naive
//      `used + amount` would overflow is still correctly REJECTED (never trapped), because the
//      ledger compares against the `limit - used` headroom instead of forming the sum;
//   4. release reduces used; releasing more than used returns err(Underflow), used unchanged;
//   5. dimensions are independent (charging Memory never affects NetBytes).
//
// FOLLOW-UP (out of scope): migrating the existing scattered budget call-sites onto this ledger.

import "kernel/core/ledger.mc";

const U64_MAX: u64 = 0xFFFF_FFFF_FFFF_FFFF;

global g_ledger: Ledger;

// true iff `ledger_charge(res, amount)` succeeds.
fn charge_ok(res: Resource, amount: u64) -> bool {
    switch ledger_charge(&g_ledger, res, amount) {
        ok(v) => { return true; }
        err(e) => { return false; }
    }
}

// true iff `ledger_charge` fails specifically with OverLimit.
fn charge_is_overlimit(res: Resource, amount: u64) -> bool {
    switch ledger_charge(&g_ledger, res, amount) {
        ok(v) => { return false; }
        err(e) => {
            switch e {
                .OverLimit => { return true; }
                _ => { return false; }
            }
        }
    }
}

// true iff `ledger_release` succeeds.
fn release_ok(res: Resource, amount: u64) -> bool {
    switch ledger_release(&g_ledger, res, amount) {
        ok(v) => { return true; }
        err(e) => { return false; }
    }
}

// true iff `ledger_release` fails specifically with Underflow.
fn release_is_underflow(res: Resource, amount: u64) -> bool {
    switch ledger_release(&g_ledger, res, amount) {
        ok(v) => { return false; }
        err(e) => {
            switch e {
                .Underflow => { return true; }
                _ => { return false; }
            }
        }
    }
}

export fn ledger_run() -> u32 {
    var pass: u32 = 1;
    ledger_init(&g_ledger);

    // Fresh ledger: every dimension unlimited (limit 0), nothing used.
    if ledger_used(&g_ledger, .Memory) != 0 { pass = 0; }
    if ledger_limit(&g_ledger, .Memory) != 0 { pass = 0; }
    if ledger_available(&g_ledger, .Memory) != U64_MAX { pass = 0; } // unlimited headroom

    // ----- (1) charge within limit succeeds; used/available update -----
    ledger_set_limit(&g_ledger, .Memory, 1000);
    if ledger_limit(&g_ledger, .Memory) != 1000 { pass = 0; }
    if ledger_available(&g_ledger, .Memory) != 1000 { pass = 0; }
    if !charge_ok(.Memory, 400) { pass = 0; }
    if ledger_used(&g_ledger, .Memory) != 400 { pass = 0; }
    if ledger_available(&g_ledger, .Memory) != 600 { pass = 0; }
    if !charge_ok(.Memory, 600) { pass = 0; } // exactly to the limit is allowed
    if ledger_used(&g_ledger, .Memory) != 1000 { pass = 0; }
    if ledger_available(&g_ledger, .Memory) != 0 { pass = 0; }

    // ----- (2) charge over limit returns OverLimit and does NOT mutate used -----
    if !charge_is_overlimit(.Memory, 1) { pass = 0; }   // 1 over a full account
    if ledger_used(&g_ledger, .Memory) != 1000 { pass = 0; } // unchanged after the refusal

    // ----- (3) overflow EDGE: limit/used near u64 max, huge amount rejected, NOT trapped -----
    // headroom = limit - used = 10; a naive `used + amount` (= U64_MAX-10 + 500) would overflow a
    // u64 (and trap under checked arithmetic). The ledger compares amount(500) against headroom(10)
    // and rejects cleanly.
    ledger_set_limit(&g_ledger, .DmaBytes, U64_MAX);
    if !charge_ok(.DmaBytes, U64_MAX - 10) { pass = 0; }       // used = U64_MAX - 10
    if ledger_used(&g_ledger, .DmaBytes) != U64_MAX - 10 { pass = 0; }
    if ledger_available(&g_ledger, .DmaBytes) != 10 { pass = 0; }
    if !charge_is_overlimit(.DmaBytes, 500) { pass = 0; }      // 500 > 10 headroom -> rejected
    if ledger_used(&g_ledger, .DmaBytes) != U64_MAX - 10 { pass = 0; } // unchanged, no wrap
    if !charge_ok(.DmaBytes, 10) { pass = 0; }                 // exactly fills to U64_MAX
    if ledger_used(&g_ledger, .DmaBytes) != U64_MAX { pass = 0; }
    if ledger_available(&g_ledger, .DmaBytes) != 0 { pass = 0; }

    // unlimited-dimension counter-overflow guard: with no limit, a charge past U64_MAX is refused
    // (it would wrap the `used` counter), not trapped.
    if !charge_ok(.IpcMessages, U64_MAX - 5) { pass = 0; }     // limit 0 (unlimited)
    if !charge_is_overlimit(.IpcMessages, 100) { pass = 0; }   // 100 > (U64_MAX - used) headroom
    if ledger_used(&g_ledger, .IpcMessages) != U64_MAX - 5 { pass = 0; }

    // ----- (4) release reduces used; over-release returns Underflow, used unchanged -----
    if !release_ok(.Memory, 250) { pass = 0; }
    if ledger_used(&g_ledger, .Memory) != 750 { pass = 0; }
    if ledger_available(&g_ledger, .Memory) != 250 { pass = 0; }
    if !release_is_underflow(.Memory, 751) { pass = 0; }       // > used(750) -> Underflow
    if ledger_used(&g_ledger, .Memory) != 750 { pass = 0; }    // unchanged after the refusal
    if !release_ok(.Memory, 750) { pass = 0; }                 // release exactly to zero
    if ledger_used(&g_ledger, .Memory) != 0 { pass = 0; }

    // ----- (5) dimensions are independent -----
    ledger_init(&g_ledger);
    ledger_set_limit(&g_ledger, .Memory, 100);
    ledger_set_limit(&g_ledger, .NetBytes, 100);
    if !charge_ok(.Memory, 60) { pass = 0; }
    if ledger_used(&g_ledger, .Memory) != 60 { pass = 0; }
    if ledger_used(&g_ledger, .NetBytes) != 0 { pass = 0; }    // NetBytes untouched
    if ledger_available(&g_ledger, .NetBytes) != 100 { pass = 0; }
    if !charge_ok(.NetBytes, 30) { pass = 0; }
    if ledger_used(&g_ledger, .Memory) != 60 { pass = 0; }     // Memory untouched by NetBytes charge
    if ledger_used(&g_ledger, .NetBytes) != 30 { pass = 0; }

    return pass;
}
