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

// A copyable handle to a grant, carried in an IPC message (the server re-validates it
// against the live grant via `grant_open` before each use).
struct GrantRef {
    base: PAddr,
    len: usize,
    gen: u32,
}

enum GrantError {
    OutOfBounds, // access outside the granted region
    Revoked,     // the grant was revoked since this handle was issued
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

// Server side: validate a ref against the live grant (catches use-after-revoke).
export fn grant_open(g: *Grant, r: GrantRef) -> Result<bool, GrantError> {
    if r.gen != g.gen {
        return err(.Revoked);
    }
    return ok(true);
}

// Server side: copy `n` bytes out of the granted region (offset `off`) to `dst`.
export fn grant_copy_out(r: *GrantRef, off: usize, dst: PAddr, n: usize) -> Result<bool, GrantError> {
    if off >= r.len {
        return err(.OutOfBounds);
    }
    if n > (r.len - off) {
        return err(.OutOfBounds);
    }
    mem_copy(dst, pa_offset(r.base, off), n);
    return ok(true);
}

// Server side: copy `n` bytes from `src` into the granted region at offset `off`.
export fn grant_copy_in(r: *GrantRef, off: usize, src: PAddr, n: usize) -> Result<bool, GrantError> {
    if off >= r.len {
        return err(.OutOfBounds);
    }
    if n > (r.len - off) {
        return err(.OutOfBounds);
    }
    mem_copy(pa_offset(r.base, off), src, n);
    return ok(true);
}
