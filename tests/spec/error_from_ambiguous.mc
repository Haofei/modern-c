// SPEC: section=21
// SPEC: milestone=error-coercion
// SPEC: phase=sema
// SPEC: expect=compile_error
// SPEC: check=E_AMBIGUOUS_ERROR_CONVERSION

// G8 regression: two `#[error_from]` conversions for the SAME (source, target)
// error types are ambiguous — the resolver would silently pick one by iteration
// order. The checker must reject rather than accept an arbitrary winner.

enum LowErr { io, eof }
enum HighErr { low, other }

#[error_from] fn conv_a(e: LowErr) -> HighErr { return HighErr.low; }
#[error_from] fn conv_b(e: LowErr) -> HighErr { return HighErr.other; } // EXPECT_ERROR: E_AMBIGUOUS_ERROR_CONVERSION
