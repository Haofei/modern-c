// std/grant — bounded, revocable memory grants (the MINIX safe-sharing primitive).
//
// When a client hands a server a buffer, passing a raw address lets the server touch
// anything. A `Grant` delegates access to *exactly* a [base, len) region: every access
// is bounds-checked (a typed `OutOfBounds`, not a wild store), so a server can only read
// or write within what it was granted. Revocation bumps `gen`; a server holding a stale
// `GrantRef` (from before a revoke) fails to `grant_open` — use-after-revoke caught,
// the same generational trick as std/arena handles. This is least privilege for memory:
// a server cannot exceed its grant.

import "std/addr.mc";
import "std/mem.mc";
import "std/math.mc";

struct Grant {
    base: PAddr,
    len: usize,
    gen: u32, // bumped on revoke
}

// A copyable handle to a grant, carried in an IPC message. It is *untrusted*: a server (or
// anything on the IPC path) can fabricate or widen one, so its `base`/`len` are never used to
// bound an access. The authoritative region always comes from the live `Grant`; the ref is
// re-validated against it (`grant_open`, and every copy) before any memory is touched.
struct GrantRef {
    base: PAddr,
    len: usize,
    gen: u32,
}

enum GrantError {
    OutOfBounds, // access outside the granted region (or a forged/widened ref)
    Revoked,     // the grant was revoked since this handle was issued
}

// Validate an (untrusted) ref against the live grant: the generation must match (else the
// grant was revoked since the ref was issued) and the ref's region must match the grant
// exactly (else it was forged or widened). Returns ok only for a faithful, current ref.
fn grant_check(g: *Grant, r: GrantRef) -> Result<bool, GrantError> {
    if r.gen != g.gen {
        return err(.Revoked);
    }
    if !pa_eq(r.base, g.base) || r.len != g.len {
        return err(.OutOfBounds); // forged or widened ref — region doesn't match the grant
    }
    return ok(true);
}

// Owner side: grant access to [base, base+len).
export fn grant_make(base: PAddr, len: usize) -> Grant {
    return .{ .base = base, .len = len, .gen = 0 };
}

// Owner side: hand out a reference to pass to a server.
export fn grant_ref(g: *Grant) -> GrantRef {
    return .{ .base = g.base, .len = g.len, .gen = g.gen };
}

// Owner side: revoke — outstanding refs become stale.
export fn grant_revoke(g: *mut Grant) -> void {
    g.gen = wrapping_add_u32(g.gen, 1);
}

// Server side: validate a ref against the live grant (catches use-after-revoke and forgery).
export fn grant_open(g: *Grant, r: GrantRef) -> Result<bool, GrantError> {
    return grant_check(g, r);
}

// Server side: copy `n` bytes out of the granted region (offset `off`) to `dst`. The ref is
// re-validated against the live grant on this access, and the bounds are taken from the grant
// (`g.base`/`g.len`) — never from the untrusted ref — so a forged/widened ref cannot reach
// outside the granted region.
export fn grant_copy_out(g: *Grant, r: GrantRef, off: usize, dst: PAddr, n: usize) -> Result<bool, GrantError> {
    switch grant_check(g, r) {
        ok(b) => {}
        err(e) => { return err(e); }
    }
    if off >= g.len {
        return err(.OutOfBounds);
    }
    if n > (g.len - off) {
        return err(.OutOfBounds);
    }
    mem_copy(dst, pa_offset(g.base, off), n);
    return ok(true);
}

// Server side: copy `n` bytes from `src` into the granted region at offset `off`. Validated
// and bounded against the live grant exactly as `grant_copy_out`.
export fn grant_copy_in(g: *Grant, r: GrantRef, off: usize, src: PAddr, n: usize) -> Result<bool, GrantError> {
    switch grant_check(g, r) {
        ok(b) => {}
        err(e) => { return err(e); }
    }
    if off >= g.len {
        return err(.OutOfBounds);
    }
    if n > (g.len - off) {
        return err(.OutOfBounds);
    }
    mem_copy(pa_offset(g.base, off), src, n);
    return ok(true);
}
