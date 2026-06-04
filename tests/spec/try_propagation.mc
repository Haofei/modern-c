// SPEC: section=10,21,D.1
// SPEC: milestone=try-propagation
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_TRY_REQUIRES_RESULT_OR_NULLABLE,E_RETURN_TYPE_MISMATCH

fn accept_nullable_try(maybe: ?*const u8) -> *const u8 {
    return maybe?;
}

fn accept_result_try(result: Result<u32, Error>) -> u32 {
    return result?;
}

fn accept_result_pointer_try(result: Result<*mut u8, Error>) -> *mut u8 {
    return result?;
}

fn reject_result_try_return_type(result: Result<u32, Error>) -> *mut u8 {
    // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
    return result?;
}

fn reject_nullable_try_return_type(maybe: ?*const u8) -> u32 {
    // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
    return maybe?;
}

fn reject_integer_try(n: u32) -> u32 {
    // EXPECT_ERROR: E_TRY_REQUIRES_RESULT_OR_NULLABLE
    return n?;
}

fn reject_bool_try(flag: bool) -> bool {
    // EXPECT_ERROR: E_TRY_REQUIRES_RESULT_OR_NULLABLE
    return flag?;
}

fn reject_non_null_pointer_try(p: *const u8) -> *const u8 {
    // EXPECT_ERROR: E_TRY_REQUIRES_RESULT_OR_NULLABLE
    return p?;
}
