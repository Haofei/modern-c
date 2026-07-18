// SPEC: section=31
// SPEC: milestone=opaque-struct
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_PRIVATE_FIELD

// Field privacy for `opaque struct` (section 31): the fields of an opaque struct are
// private to the struct's associated functions (`impl Name { … }`). Outside code may
// hold, pass, and return a value but may not construct one with a struct literal, nor
// read or write its fields — so a generational handle cannot be forged or inspected by
// raw field construction. Verified for both a plain and a generic opaque struct.

opaque struct Handle { idx: u32, gen: u32 }

impl Handle {
    // associated functions: full access to the private fields
    fn make(i: u32, g: u32) -> Handle { return .{ .idx = i, .gen = g }; }
    fn generation(h: Handle) -> u32 { return h.gen; }
    fn matches(h: Handle, g: u32) -> bool { return h.gen == g; }
}

opaque struct Slot<T> { index: usize, gen: u32 }

impl Slot {
    fn make(comptime T: type, i: usize, g: u32) -> Slot<T> { return .{ .index = i, .gen = g }; }
    fn stale(comptime T: type, s: Slot<T>, current: u32) -> bool { return s.gen != current; }
}

// A user identifier may contain `__`. Sharing the first mangled-name segment
// must not make `impl Vault` an associated implementation of `Vault__Inner`.
opaque struct Vault__Inner { secret: u64 }
struct Vault { marker: u8 }

impl Vault {
    fn reject_owner_prefix_read(v: Vault__Inner) -> u64 {
        // EXPECT_ERROR: E_PRIVATE_FIELD
        return v.secret;
    }

    fn reject_owner_prefix_construct() -> Vault__Inner {
        // EXPECT_ERROR: E_PRIVATE_FIELD
        return .{ .secret = 7 };
    }
}

// --- accepted: outside code holds, passes, and returns opaque values (no field use) ---
fn accept_hold_plain(h: Handle) -> Handle { return h; }
fn accept_hold_generic(s: Slot<u32>) -> Slot<u32> { return s; }
fn accept_via_api(g: u32) -> u32 {
    let h: Handle = Handle.make(1, g);
    return Handle.generation(h);
}

// --- rejected: constructing an opaque struct outside its `impl` forges a handle ---
fn reject_forge_plain() -> Handle {
    // EXPECT_ERROR: E_PRIVATE_FIELD
    return .{ .idx = 0, .gen = 999 };
}

fn reject_forge_generic() -> Slot<u32> {
    // EXPECT_ERROR: E_PRIVATE_FIELD
    return .{ .index = 0, .gen = 999 };
}

// --- rejected: reading a private field outside the `impl` ---
fn reject_read_plain(h: Handle) -> u32 {
    // EXPECT_ERROR: E_PRIVATE_FIELD
    return h.gen;
}

fn reject_read_generic(s: Slot<u32>) -> u32 {
    // EXPECT_ERROR: E_PRIVATE_FIELD
    return s.gen;
}

// --- rejected: writing a private field outside the `impl` ---
fn reject_write_plain(h: Handle) -> u32 {
    var hh: Handle = h;
    // EXPECT_ERROR: E_PRIVATE_FIELD
    hh.gen = 1;
    return Handle.generation(hh);
}
