// Revoke cascade for delegated capability chains (kernel/lib/granttab, P1.6). Authority handed
// down a delegation chain must be reclaimable from the top: revoking a grant revokes every
// grant delegated (transitively) from it. Delegation also attenuates — a child grant's region
// must be a sub-region of its parent's, never wider.
import "kernel/lib/granttab.mc";
import "std/grant.mc";
import "std/addr.mc";

global g_tab: GrantTable;
global g_buf: [64]u8;

export fn grantcascade_run() -> u32 {
    var pass: u32 = 1;
    grant_table_init(&g_tab);

    let base: usize = (&g_buf[0]) as usize;

    // Owner A (endpoint 1,0) makes a root grant g0 over the whole 64-byte buffer.
    var g0: usize = 0;
    switch grant_table_make(&g_tab, 1, 0, pa(base), 64) {
        ok(gi) => { g0 = gi; }
        err(ge) => { pass = 0; }
    }

    // A delegates g0 -> g1 to B (endpoint 2,0), attenuated to [base, base+32) ⊆ g0.
    var g1: usize = 0;
    switch grant_table_delegate(&g_tab, g0, 2, 0, pa(base), 32) {
        ok(gi) => { g1 = gi; }
        err(ge) => { pass = 0; }
    }

    // B delegates g1 -> g2 to C (endpoint 3,0), further attenuated to [base+8, base+8+16) ⊆ g1.
    var g2: usize = 0;
    switch grant_table_delegate(&g_tab, g1, 3, 0, pa(base + 8), 16) {
        ok(gi) => { g2 = gi; }
        err(ge) => { pass = 0; }
    }

    if grant_table_count(&g_tab) != 3 { pass = 0; }

    // A delegation that EXCEEDS its parent must be rejected (attenuation). g1 covers 32 bytes;
    // asking to delegate 64 from it (widening) is OutOfBounds.
    switch grant_table_delegate(&g_tab, g1, 4, 0, pa(base), 64) {
        ok(gi) => { pass = 0; } // should not succeed
        err(ge) => {}           // expected OutOfBounds
    }
    // A delegation starting before the parent's region is likewise rejected.
    switch grant_table_delegate(&g_tab, g2, 5, 0, pa(base), 16) {
        ok(gi) => { pass = 0; }
        err(ge) => {}
    }

    // Grab refs for g0/g1/g2 and confirm all three open/valid before the cascade.
    var r0: GrantRef = .{ .base = pa(0), .len = 0, .gen = 0 };
    var r1: GrantRef = .{ .base = pa(0), .len = 0, .gen = 0 };
    var r2: GrantRef = .{ .base = pa(0), .len = 0, .gen = 0 };
    switch grant_table_ref(&g_tab, g0) { ok(r) => { r0 = r; } err(e) => { pass = 0; } }
    switch grant_table_ref(&g_tab, g1) { ok(r) => { r1 = r; } err(e) => { pass = 0; } }
    switch grant_table_ref(&g_tab, g2) { ok(r) => { r2 = r; } err(e) => { pass = 0; } }
    switch grant_table_open(&g_tab, g0, r0) { ok(b) => {} err(e) => { pass = 0; } }
    switch grant_table_open(&g_tab, g1, r1) { ok(b) => {} err(e) => { pass = 0; } }
    switch grant_table_open(&g_tab, g2, r2) { ok(b) => {} err(e) => { pass = 0; } }

    // CASCADE: revoke the root g0. g0, g1 and g2 must all be reclaimed (root + 2 descendants).
    switch grant_table_revoke_cascade(&g_tab, g0) {
        ok(n) => { if n != 3 { pass = 0; } }
        err(e) => { pass = 0; }
    }
    if grant_table_count(&g_tab) != 0 { pass = 0; }

    // Every ref down the chain now fails closed (stale generation / gone).
    switch grant_table_open(&g_tab, g0, r0) { ok(b) => { pass = 0; } err(e) => {} }
    switch grant_table_open(&g_tab, g1, r1) { ok(b) => { pass = 0; } err(e) => {} }
    switch grant_table_open(&g_tab, g2, r2) { ok(b) => { pass = 0; } err(e) => {} }

    return pass;
}
