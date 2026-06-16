// Exercises the kernel/lib ResourceAccount quota counter end-to-end. resacct_run() returns 1
// only if every property holds: fail-closed charge (no partial reservation at the ceiling),
// saturating uncharge (no underflow below zero), and correct available/used/reset accounting.

import "kernel/lib/resacct.mc";

global g_acct: ResourceAccount;

export fn resacct_run() -> u32 {
    resacct_init(&g_acct, 100);

    // Fresh account: nothing used, full budget available.
    if resacct_used(&g_acct) != 0 {
        return 0;
    }
    if resacct_available(&g_acct) != 100 {
        return 0;
    }

    // Charge 40 -> ok, new total 40, available 60.
    switch resacct_charge(&g_acct, 40) {
        ok(total) => {
            if total != 40 {
                return 0;
            }
        }
        err(e) => {
            return 0;
        }
    }
    if resacct_used(&g_acct) != 40 {
        return 0;
    }
    if resacct_available(&g_acct) != 60 {
        return 0;
    }

    // Charge 70 -> OverQuota (40+70 > 100). Must fail closed: used stays 40, no partial charge.
    switch resacct_charge(&g_acct, 70) {
        ok(total) => {
            return 0;
        }
        err(e) => {
            // expected
        }
    }
    if resacct_used(&g_acct) != 40 {
        return 0; // a partial charge would have corrupted the counter
    }
    if resacct_available(&g_acct) != 60 {
        return 0;
    }

    // Charge 60 -> ok, exactly at the limit: used 100, available 0.
    switch resacct_charge(&g_acct, 60) {
        ok(total) => {
            if total != 100 {
                return 0;
            }
        }
        err(e) => {
            return 0;
        }
    }
    if resacct_used(&g_acct) != 100 {
        return 0;
    }
    if resacct_available(&g_acct) != 0 {
        return 0;
    }

    // Charge 1 at the ceiling -> OverQuota, used unchanged.
    switch resacct_charge(&g_acct, 1) {
        ok(total) => {
            return 0;
        }
        err(e) => {
            // expected
        }
    }
    if resacct_used(&g_acct) != 100 {
        return 0;
    }

    // Uncharge the whole reservation -> used 0, full budget back.
    resacct_uncharge(&g_acct, 100);
    if resacct_used(&g_acct) != 0 {
        return 0;
    }
    if resacct_available(&g_acct) != 100 {
        return 0;
    }

    // Uncharge from an empty account -> saturates at 0, never underflows.
    resacct_uncharge(&g_acct, 5);
    if resacct_used(&g_acct) != 0 {
        return 0;
    }

    // Reset after a fresh charge drops used back to 0.
    switch resacct_charge(&g_acct, 25) {
        ok(total) => {}
        err(e) => {
            return 0;
        }
    }
    if resacct_used(&g_acct) != 25 {
        return 0;
    }
    resacct_reset(&g_acct);
    if resacct_used(&g_acct) != 0 {
        return 0;
    }
    if resacct_available(&g_acct) != 100 {
        return 0;
    }

    return 1;
}
