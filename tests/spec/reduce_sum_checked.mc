// SPEC: section=8.2
// SPEC: milestone=checked-reduction
// SPEC: phase=sema,lower-c
// SPEC: expect=pass,compile_error
// SPEC: check=E_REDUCE_REQUIRES_INTEGER,E_REDUCE_ARG_NOT_SLICE,E_CALL_ARG_COUNT

// reduce.sum_checked<T>(xs: []const T) -> Result<T, Overflow> (§8.2): sum in an
// abstract/wide integer domain, returning Overflow only if the final result
// does not fit T. Distinct from stepwise checked addition.

fn sum_u32(xs: []const u32) -> Result<u32, Overflow> {
    return reduce.sum_checked<u32>(xs);
}

fn sum_i64(xs: []const i64) -> Result<i64, Overflow> {
    return reduce.sum_checked<i64>(xs);
}

fn sum_u8(xs: []const u8) -> Result<u8, Overflow> {
    return reduce.sum_checked<u8>(xs);
}

// Restricted to integer types (§8.2).
fn reject_float_element(xs: []const f64) -> Result<f64, Overflow> {
    // EXPECT_ERROR: E_REDUCE_REQUIRES_INTEGER
    return reduce.sum_checked<f64>(xs);
}

// The argument must be a slice of the element type.
fn reject_scalar_arg(x: u32) -> Result<u32, Overflow> {
    // EXPECT_ERROR: E_REDUCE_ARG_NOT_SLICE
    return reduce.sum_checked<u32>(x);
}

// Exactly one slice argument.
fn reject_arg_count(xs: []const u32, ys: []const u32) -> Result<u32, Overflow> {
    // EXPECT_ERROR: E_CALL_ARG_COUNT
    return reduce.sum_checked<u32>(xs, ys);
}
