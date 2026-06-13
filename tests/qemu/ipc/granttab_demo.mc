// Grant-based IPC payloads: a client shares a bounded buffer with a server via a GrantRef
// (carried in an IPC message); the server's access is bounds-checked, and when the client
// dies the kernel revokes its grants so the server can no longer touch the dead client's
// memory through a stale ref.
import "kernel/lib/granttab.mc";
import "std/grant.mc";
import "std/addr.mc";

global g_tab: GrantTable;
global g_src: [16]u8;
global g_dst: [16]u8;

export fn granttab_run() -> u32 {
    var pass: u32 = 1;
    grant_table_init(&g_tab);
    g_src[0] = 0xAA; g_src[1] = 0xBB; g_src[2] = 0xCC;

    // client pid 5 grants its 16-byte buffer to a server
    var id: usize = 0;
    switch grant_table_make(&g_tab, 5, 0, pa((&g_src[0]) as usize), 16) { // owner (pid 5, gen 0)
        ok(gi) => { id = gi; }
        err(ge) => { pass = 0; }
    }
    if grant_table_count(&g_tab) != 1 { pass = 0; }

    // the server receives a ref (over IPC) and validates it against the live grant
    var gref: GrantRef = .{ .base = pa(0), .len = 0, .gen = 0 };
    switch grant_table_ref(&g_tab, id) {
        ok(r) => { gref = r; }
        err(re) => { pass = 0; }
    }
    switch grant_table_open(&g_tab, id, gref) {
        ok(ob) => {}
        err(oe) => { pass = 0; }
    }

    // bounded copy out: read 3 bytes from inside the granted region (validated against the
    // live grant in the table, not the untrusted ref the server carries)
    switch grant_table_copy_out(&g_tab, id, gref, 0, pa((&g_dst[0]) as usize), 3) {
        ok(cb) => {}
        err(ce) => { pass = 0; }
    }
    if g_dst[0] != 0xAA { pass = 0; }
    if g_dst[2] != 0xCC { pass = 0; }
    // out of bounds: copying past the granted length fails closed (no wild access)
    switch grant_table_copy_out(&g_tab, id, gref, 0, pa((&g_dst[0]) as usize), 99) {
        ok(cb2) => { pass = 0; }
        err(ce2) => {}
    }
    // a forged ref that widens its claimed length cannot escape the grant: bounds come from
    // the live grant in the table, so the over-long copy fails closed
    var forged: GrantRef = .{ .base = pa((&g_src[0]) as usize), .len = 4096, .gen = gref.gen };
    switch grant_table_copy_out(&g_tab, id, forged, 0, pa((&g_dst[0]) as usize), 64) {
        ok(cb3) => { pass = 0; }
        err(ce3) => {}
    }

    // REVOKE ON DEATH: client pid 5 exits -> the kernel revokes all of its grants
    if grant_table_revoke_owner(&g_tab, 5, 0) != 1 { pass = 0; }
    // the server's ref is now stale: open fails Revoked, so no use-after-death
    switch grant_table_open(&g_tab, id, gref) {
        ok(ob2) => { pass = 0; }
        err(oe2) => {}
    }
    // revoking some other pid's grants removes nothing
    if grant_table_revoke_owner(&g_tab, 9, 0) != 0 { pass = 0; }
    return pass;
}
