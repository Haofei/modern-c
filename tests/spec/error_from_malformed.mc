// SPEC: section=21
// SPEC: milestone=error-coercion
// SPEC: phase=sema
// SPEC: expect=compile_error
// SPEC: check=E_INVALID_ERROR_FROM

// G8 regression: a malformed `#[error_from]` fn (not shaped `fn(E1) -> E2` with a
// single named source-error parameter and a named target-error return) must be
// rejected at its declaration — previously it was silently ignored and later
// surfaced misleadingly as E_NO_ERROR_CONVERSION at the `?` site.

enum LowErr { io, eof }
enum HighErr { low, other }

#[error_from] fn bad_arity(e: LowErr, extra: u32) -> HighErr { return HighErr.low; } // EXPECT_ERROR: E_INVALID_ERROR_FROM
