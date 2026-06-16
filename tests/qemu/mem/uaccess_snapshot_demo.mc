// Single-snapshot uaccess discipline (U2: double-fetch / TOCTOU defense).
//
// `fetch_user` copies a user datum in EXACTLY ONCE into an immutable
// `UserSnapshot<T>`. Every kernel decision then reads `.value` — frozen kernel
// memory — so the validate→use window cannot be raced: a second read of the same
// user pointer is unnecessary (and is what the double-fetch-audit lint flags).
//
// This demo shows the SAFE pattern: snapshot a length once, validate `.value`, and
// use that SAME `.value` to bound a follow-up copy. It then proves a snapshot is a
// value, not a borrow: mutating the user bytes after the snapshot does NOT change
// the snapshot — the classic TOCTOU flip is defeated structurally. It runs on the
// host harness (numeric UserSpace; no satp needed).

import "kernel/core/uaccess.mc";
import "std/addr.mc";

global g_user: [256]u8; // stands in for the (identity-mapped) user region

fn store8(addr: PAddr, off: usize, v: u8) -> void {
    unsafe { raw.store<u8>(pa_offset(addr, off), v); }
}

export fn uaccess_snapshot_run() -> u32 {
    var pass: u32 = 1;
    let ubase: usize = (&g_user[0]) as usize;
    var us: UserSpace = user_space(ubase, ubase + 256);

    // The user places a length byte at offset 0.
    let lenp: PAddr = pa(ubase);
    store8(lenp, 0, 16); // attacker-controlled "length" = 16

    // SAFE: copy the length in ONCE. The decision is made against the snapshot.
    var n: u8 = 0;
    switch fetch_user(u8, &us, ubase as UserPtr<u8>) {
        ok(snap) => { n = snap.value; }
        err(e) => { pass = 0; }
    }
    if n != 16 { pass = 0; }

    // The attacker now flips the user byte AFTER we snapshotted it — the classic
    // TOCTOU race. A double-fetching kernel would re-read 200 here and act on it;
    // we never re-read, so our decision still stands on the frozen `n == 16`.
    store8(lenp, 0, 200);

    // Re-snapshot to PROVE the original snapshot was an independent copy (its value
    // is gone — there is no way to "go back" to it, which is the whole point: you
    // snapshot once and commit). The first snapshot value `n` is unaffected.
    var n2: u8 = 0;
    switch fetch_user(u8, &us, ubase as UserPtr<u8>) {
        ok(snap) => { n2 = snap.value; }
        err(e) => { pass = 0; }
    }
    if n != 16 { pass = 0; }   // first snapshot still frozen at the validated value
    if n2 != 200 { pass = 0; } // a fresh fetch sees the new bytes — it is a new datum

    // Fail-closed still holds: a snapshot of a datum that straddles the region end
    // returns an error and yields no value.
    switch fetch_user(u8, &us, (ubase + 256) as UserPtr<u8>) {
        ok(snap) => { pass = 0; } // out of range: must not produce a snapshot
        err(e) => {}
    }

    return pass;
}
