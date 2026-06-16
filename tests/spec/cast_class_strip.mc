// SPEC: section=15,16,D.4
// SPEC: milestone=cast-class-strip
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_SECRET_DECLASSIFY,E_USERPTR_CAST_DEREF,E_BITCAST_TYPE

// An `as`-cast or pointer-`bitcast` must not silently strip a safety class to a
// less-safe one. Without this gate, `s as u32` declassifies a Secret with no
// `unsafe`, `p as *u32` turns an unvalidated UserPtr into a derefable kernel
// pointer, and `bitcast<*Shadow>(pt)` reads an opaque pointee's private bytes
// through a same-shape plain mirror. The class-preserving / widening casts
// (numeric, UserPtr<->usize, ordinary pointer<->pointer) stay accepted.

opaque struct Tainted<T> {
    raw: T,
}

opaque struct Guarded<T> {
    locked: u32,
    data: T,
}

// A plain, same-shape mirror — exists only to demonstrate the reinterpret hole.
struct Shadow {
    raw: u32,
}

struct ShadowGuard {
    locked: u32,
    data: u32,
}

// ---- allowed: class-preserving / widening `as`-casts -------------------------

fn accept_numeric_widen(x: u32) -> u64 {
    return x as u64;
}

fn accept_userptr_to_usize(p: UserPtr<u32>) -> usize {
    // uaccess.mc relies on this exact direction; it can never be dereferenced.
    return p as usize;
}

fn accept_usize_to_userptr(a: usize) -> UserPtr<u32> {
    return a as UserPtr<u32>;
}

fn accept_secret_in_unsafe(s: Secret<u32>) -> u32 {
    // Declassify is allowed when the caller asserts the timing channel via unsafe.
    unsafe {
        return s as u32;
    }
}

fn accept_pointer_to_pointer(p: *u32) -> *u8 {
    // Ordinary kernel pointer reinterpret — neither side is an opaque class.
    return bitcast<*u8>(p);
}

// ---- rejected: Secret declassified by `as` (no unsafe) -----------------------

fn reject_secret_strip(s: Secret<u32>) -> u32 {
    return s as u32; // EXPECT_ERROR: E_SECRET_DECLASSIFY
}

// ---- rejected: UserPtr cast to a derefable kernel pointer --------------------

fn reject_userptr_cast_deref(p: UserPtr<u32>) -> *u32 {
    return p as *u32; // EXPECT_ERROR: E_USERPTR_CAST_DEREF
}

// ---- rejected: pointer-bitcast OUT OF an opaque (Tainted) pointee ------------

fn reject_tainted_bitcast(pt: *Tainted<u32>) -> *Shadow {
    return bitcast<*Shadow>(pt); // EXPECT_ERROR: E_BITCAST_TYPE
}

// ---- rejected: pointer-bitcast OUT OF a Guarded pointee ----------------------

fn reject_guarded_bitcast(pg: *Guarded<u32>) -> *ShadowGuard {
    return bitcast<*ShadowGuard>(pg); // EXPECT_ERROR: E_BITCAST_TYPE
}

// ---- rejected: pointer-bitcast INTO an opaque pointee (reverse direction) ----

fn reject_into_opaque_bitcast(p: *Shadow) -> *Tainted<u32> {
    return bitcast<*Tainted<u32>>(p); // EXPECT_ERROR: E_BITCAST_TYPE
}
