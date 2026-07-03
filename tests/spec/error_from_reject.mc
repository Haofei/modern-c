// SPEC: section=10,21
// SPEC: milestone=error-coercion
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_NO_ERROR_CONVERSION

// G8: `EXPR?` propagates a `Result<_, E1>` out of a function returning
// `Result<_, E2>`. When `E1 != E2` the `?` must invoke an explicit
// `#[error_from]` conversion; without one the checker rejects rather than
// silently reinterpreting the error payload bits. (The accept path — with a
// declared `#[error_from]` conversion — is exercised as a runtime gate by
// tests/exec/error_from_run.mc.)

enum LowErr { io, eof }
enum HighErr { low, other }

fn make_low() -> Result<u32, LowErr> {
    return err(LowErr.io);
}

// No `#[error_from]` conversion from LowErr to HighErr exists, so `?` cannot
// convert the propagated error to this function's error type.
fn propagate_without_conversion() -> Result<u32, HighErr> {
    let x: u32 = make_low()?; // EXPECT_ERROR: E_NO_ERROR_CONVERSION
    return ok(x);
}

// Same error type on both sides: `?` propagates the error as-is, unchanged.
fn propagate_same_error() -> Result<u32, LowErr> {
    let x: u32 = make_low()?;
    return ok(x);
}
