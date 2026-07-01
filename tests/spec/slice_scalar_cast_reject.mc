// SPEC: section=9
// SPEC: milestone=slice-cast-soundness
// SPEC: phase=sema
// SPEC: expect=compile_error
// SPEC: check=E_ILLEGAL_SLICE_CAST

// SOUNDNESS (language gap G12 #1): a slice (`[]T`) is a fat pointer (ptr+len). A scalar /
// usize has no length component, so `scalar as []T` cannot be lowered — the backend would
// cast only the scalar and DROP the length, fabricating a slice with a garbage length over
// an arbitrary address. The checker must reject any NON-slice -> slice `as` cast (only a
// slice-to-slice reinterpret, e.g. `[]mut T as []const T`, is representable). Build a real
// slice with a slicing expression, `mem.as_bytes`, or a string literal.

fn forge_slice_from_scalar(x: usize) -> usize {
    let s: []const u8 = x as []const u8; // EXPECT_ERROR: E_ILLEGAL_SLICE_CAST
    return s.len;
}
