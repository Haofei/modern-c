// SPEC: section=15,16,D.4
// SPEC: milestone=soundness-opaque-declassify
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_OPAQUE_DECLASSIFY

// SOUNDNESS SOURCE OF TRUTH — value-level `as` declassification of an opaque struct.
//
// An `opaque struct`'s fields are private to its associated functions (`impl`): outside
// code may hold and pass the value but not read its fields. A value-level `as`-cast
// pierced that privacy — `b as <inner>` extracted the hidden `.raw`/`.bits`/etc. with no
// `E_PRIVATE_FIELD`, no accessor, and no `unsafe`. The earlier cast-strip gate keyed on
// the ENUMERATED built-in classes (Secret/UserPtr) and the bitcast pointee, so it missed
// value-`as` on a general opaque struct — including the real `kernel/core/uaccess`
// `Tainted<T>`, where `t as u8` yields the unchecked raw length and defeats U3.
//
// This fixture generalizes the gate to the `opaque` PROPERTY itself: a value-`as` whose
// source is any opaque struct is a gated declassification (E_OPAQUE_DECLASSIFY), uniformly
// covering Tainted/Cap/Rights/Guarded and any user-defined opaque struct. Controlled
// escapes stay open: an `unsafe` block, an identity cast to the SAME opaque type, and the
// type's own `impl` (which has full access to its representation).
//
// Each `reject_*` carries an inline `// EXPECT_ERROR:` the harness matches against a real
// diagnostic on that line; each `accept_*` MUST compile clean. If the channel re-opens
// (a reject stops rejecting) or a legitimate cast regresses, `zig build test` turns red.

opaque struct Box {
    raw: u8,
}

// A generic opaque struct mirroring uaccess `Tainted<T>` — the carrier whose raw scalar
// must only be read through a checked accessor.
opaque struct Tainted<T> {
    raw: T,
}

// A plain (non-opaque) struct — casting it is not a privacy pierce.
struct Plain {
    raw: u8,
}

// ---- rejected: value-`as` extracts an opaque struct's private field ----------

fn reject_box_strip(b: Box) -> u8 {
    return b as u8; // EXPECT_ERROR: E_OPAQUE_DECLASSIFY
}

fn reject_generic_opaque_strip(t: Tainted<u32>) -> u32 {
    // The exact uaccess shape: `t as <inner>` would yield the unchecked raw value,
    // bypassing checked_len / checked_index (U3).
    return t as u32; // EXPECT_ERROR: E_OPAQUE_DECLASSIFY
}

// ---- allowed: controlled escapes & legitimate casts --------------------------

fn accept_box_in_unsafe(b: Box) -> u8 {
    // The single controlled declassification: the caller asserts the invariant.
    unsafe {
        return b as u8;
    }
}

fn accept_box_identity(b: Box) -> Box {
    // Identity / no-op cast to the SAME opaque type extracts nothing.
    return b as Box;
}

fn accept_numeric_widen(x: u32) -> u64 {
    // Source is a scalar, not an opaque struct.
    return x as u64;
}

fn accept_plain_struct_cast(p: Plain) -> Plain {
    // Source is a NON-opaque struct — no privacy to pierce.
    return p as Plain;
}

// The opaque type's OWN `impl` legitimately names its representation. (It reads `.raw`
// by field access, not by `as`; an `as` here would still be in-owner and allowed.)
impl Box {
    fn peek(self: Box) -> u8 {
        return self.raw;
    }
}

impl Tainted {
    fn peek(comptime T: type, self: Tainted<T>) -> T {
        return self.raw;
    }
}
