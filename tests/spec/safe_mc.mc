// SPEC: section=1.1
// SPEC: milestone=safe-mc
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_UNSAFE_REQUIRED

// §1.1 Safe MC: ordinary operations are safe. The compiler may not assume an error is
// impossible unless the program checked, the value came from a checked constructor, or it
// can prove the error cannot occur. Each safe primitive has a *defined language trap*
// (IntegerOverflow / Bounds / NullUnwrap) — never undefined behavior — so the operations
// below compile in safe code, while a genuinely unsafe operation (raw-pointer deref) is
// rejected outside an `unsafe` block.

// Accepted: checked arithmetic. Overflow is the defined IntegerOverflow trap, not UB.
fn safe_checked_add(a: u32, b: u32) -> u32 {
    return a + b;
}

// Accepted: bounds-checked indexing. Out-of-range is the defined Bounds trap.
fn safe_bounds_indexing(buf: []const u8, i: usize) -> u8 {
    return buf[i];
}

// Accepted: unwrapping a nullable. Null is the defined NullUnwrap trap.
fn safe_nullable_unwrap(maybe: ?*const u8) -> *const u8 {
    return maybe?;
}

// Rejected: a raw-many-pointer dereference is not a Safe MC operation — it has no defined
// trap and must be justified inside an `unsafe` block.
fn reject_unsafe_raw_deref(p: [*]const u8) -> u8 {
    // EXPECT_ERROR: E_UNSAFE_REQUIRED
    return p.*;
}
