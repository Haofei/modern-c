// Tainted untrusted lengths/indices (U3: bound-check user-derived values).
//
// A value that comes in from user space is untrusted ("tainted"). It must pass an
// explicit bound check before it can drive a length, index, copy-size, or loop bound
// — the heartbleed shape is to trust an attacker-supplied length and over-read.
//
// `Tainted<T>` carries that untrusted scalar and exposes NO raw accessor: the only way
// to get a usable value out is through `checked_len` / `checked_index` /
// `validate_bound`, which reject anything outside the kernel-chosen limit (fail closed,
// yielding no value). This demo shows the SAFE path (validate, then use) and proves the
// validators reject an over-long length and an out-of-range index. It runs on the host
// harness (numeric UserSpace; no satp needed).

import "kernel/core/uaccess.mc";
import "std/addr.mc";

global g_user: [256]u8; // stands in for the (identity-mapped) user region

// Forge a UserPtr<u8> from a test address: re-tagging an integer into the UserPtr
// address class needs `unsafe` (kernel/core/uaccess.mc idiom); the audited fetch_user
// boundary still validates it.
fn uptr(a: usize) -> UserPtr<u8> {
    var p: UserPtr<u8> = uninit;
    unsafe { p = a as UserPtr<u8>; }
    return p;
}

fn store8(addr: PAddr, off: usize, v: u8) -> void {
    unsafe { raw.store<u8>(pa_offset(addr, off), v); }
}

export fn uaccess_taint_run() -> u32 {
    var pass: u32 = 1;
    let ubase: usize = (&g_user[0]) as usize;
    var us: UserSpace = user_space(ubase, ubase + 256);

    // Our kernel destination buffer holds 64 bytes — that is the trust limit for any
    // user-supplied length that wants to copy into it.
    let KBUF_LEN: u8 = 64;

    // ---- SAFE length: user asks for 16 bytes, which fits ----
    store8(pa(ubase), 0, 16); // attacker-controlled "length" = 16
    var t_ok: Tainted<u8> = taint(u8, .{ .value = 0 });
    switch fetch_user(u8, &us, uptr(ubase)) {
        ok(snap) => { t_ok = taint(u8, snap); }
        err(e) => { pass = 0; }
    }
    // The tainted value cannot be used directly — it must pass checked_len first.
    var safe_len: u8 = 255;
    switch checked_len(u8, t_ok, KBUF_LEN) {
        ok(v) => { safe_len = v; } // now trusted: usable as a copy-size/loop-bound
        err(e) => { pass = 0; }    // 16 <= 64, must be accepted
    }
    if safe_len != 16 { pass = 0; }

    // ---- HOSTILE length: user asks for 200 bytes into a 64-byte buffer ----
    store8(pa(ubase), 1, 200); // attacker-controlled "length" = 200 (overflows KBUF_LEN)
    var t_bad: Tainted<u8> = taint(u8, .{ .value = 0 });
    switch fetch_user(u8, &us, uptr(ubase + 1)) {
        ok(snap) => { t_bad = taint(u8, snap); }
        err(e) => { pass = 0; }
    }
    var rejected: u32 = 0;
    switch checked_len(u8, t_bad, KBUF_LEN) {
        ok(v) => { pass = 0; }     // MUST NOT accept 200 > 64 — that is the over-read
        err(e) => { rejected = 1; } // fail closed: no value escapes
    }
    if rejected != 1 { pass = 0; }

    // ---- INDEX: a user index into a 64-element array ----
    // In range (63 < 64): accepted.
    store8(pa(ubase), 2, 63);
    switch fetch_user(u8, &us, uptr(ubase + 2)) {
        ok(snap) => {
            switch checked_index(u8, taint(u8, snap), KBUF_LEN) {
                ok(v) => { if v != 63 { pass = 0; } }
                err(e) => { pass = 0; } // 63 < 64 must be accepted
            }
        }
        err(e) => { pass = 0; }
    }
    // Out of range (64 == 64, not < 64): rejected.
    store8(pa(ubase), 3, 64);
    switch fetch_user(u8, &us, uptr(ubase + 3)) {
        ok(snap) => {
            var idx_rejected: u32 = 0;
            switch checked_index(u8, taint(u8, snap), KBUF_LEN) {
                ok(v) => { pass = 0; }      // off-the-end index must be rejected
                err(e) => { idx_rejected = 1; }
            }
            if idx_rejected != 1 { pass = 0; }
        }
        err(e) => { pass = 0; }
    }

    // ---- validate_bound: a non-zero floor [10, 20) ----
    store8(pa(ubase), 4, 5);  // below the floor -> rejected
    switch fetch_user(u8, &us, uptr(ubase + 4)) {
        ok(snap) => {
            switch validate_bound(u8, taint(u8, snap), 10, 20) {
                ok(v) => { pass = 0; }
                err(e) => {}
            }
        }
        err(e) => { pass = 0; }
    }
    store8(pa(ubase), 5, 15); // inside [10, 20) -> accepted
    switch fetch_user(u8, &us, uptr(ubase + 5)) {
        ok(snap) => {
            switch validate_bound(u8, taint(u8, snap), 10, 20) {
                ok(v) => { if v != 15 { pass = 0; } }
                err(e) => { pass = 0; }
            }
        }
        err(e) => { pass = 0; }
    }

    return pass;
}
