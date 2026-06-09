// Memory grants: a buffer is delegated to exactly [base, 8). An in-bounds copy works;
// an out-of-bounds copy is a typed OutOfBounds (not a wild access); after revoke, the
// stale handle no longer opens. This is the safe replacement for passing raw addresses
// across the IPC boundary.

import "std/grant.mc";
import "std/addr.mc";

global g_src: [16]u8;
global g_dst: [16]u8;

export fn grant_demo_run() -> u32 {
    var i: usize = 0;
    while i < 16 {
        g_src[i] = (i + 1) as u8;
        i = i + 1;
    }
    var g: Grant = grant_make(pa((&g_src[0]) as usize), 8); // grant only the first 8 bytes
    var r: GrantRef = grant_ref(&g);
    var pass: u32 = 1;

    let dst: PAddr = pa((&g_dst[0]) as usize);
    switch grant_copy_out(&g, r, 0, dst, 8) { // in-bounds, validated against the live grant
        ok(b) => {}
        err(e) => { pass = 0; }
    }
    if g_dst[0] != 1 { pass = 0; }
    if g_dst[7] != 8 { pass = 0; }

    switch grant_copy_out(&g, r, 4, dst, 8) { // 4+8 > 8 -> rejected, not a wild read
        ok(b) => { pass = 0; }
        err(e) => {}
    }

    // A forged/widened ref (claims a 64-byte region) cannot escape the 8-byte grant: bounds
    // come from the live grant, so the access fails closed instead of reading past it.
    var forged: GrantRef = .{ .base = pa((&g_src[0]) as usize), .len = 64, .gen = r.gen };
    switch grant_copy_out(&g, forged, 0, dst, 16) {
        ok(b) => { pass = 0; }
        err(e) => {}
    }

    grant_revoke(&g);
    switch grant_open(&g, r) { // stale ref after revoke
        ok(b) => { pass = 0; }
        err(e) => {}
    }
    return pass;
}
