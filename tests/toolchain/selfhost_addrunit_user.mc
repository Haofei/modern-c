// selfhost-addr-test fixture: exercises mcc2's two new constructs end to end — (1) bool literals
// `true`/`false`, and (2) the builtin address-class model (`PAddr`/`VAddr` opaque word-backed
// scalars + the `phys()` minting builtin + `as`-cast minting both directions) — including an
// address-class struct field and a `return .{ ... };` compound-literal return. Each exported fn is
// called from the test's C driver, which asserts known values (behavior, not just compile).

// A half-open physical range whose endpoints are the PAddr address class (struct field of an address
// class + compound-literal return path).
struct PRange {
    start: PAddr,
    end: PAddr,
}

// Bool literals: `false` / `true` as primaries (the lexer emits kw_false/kw_true). Returns a `bool`.
export fn ge10(x: usize) -> bool {
    if x < 10 {
        return false;
    }
    return true;
}

// `phys(v)` mints a PAddr from an integer word; `a as usize` reads it back — a full round trip.
export fn pa_roundtrip(v: usize) -> usize {
    let a: PAddr = phys(v);
    return a as usize;
}

// `v as VAddr` mints a VAddr via an `as`-cast (the other minting direction), read back via `as usize`.
export fn va_roundtrip(v: usize) -> usize {
    unsafe {
        let a: VAddr = v as VAddr;
        return a as usize;
    }
}

// Build a PRange and return it directly as a struct-literal — exercises the `return .{ ... };`
// compound-literal emission with address-class fields. Internal (consumed by `built_len`).
fn mk_range(start: usize, len: usize) -> PRange {
    return .{ .start = phys(start), .end = phys(start + len) };
}

// Round-trip through a PRange value: field access + address-class subtraction back to a usize length.
export fn built_len(start: usize, len: usize) -> usize {
    let r: PRange = mk_range(start, len);
    return (r.end as usize) - (r.start as usize);
}
