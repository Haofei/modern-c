// SPEC: section=10
// SPEC: milestone=nullability
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_NULL_NON_NULL_POINTER

fn accept_nullable_mut_pointer_null() -> ?*mut u8 {
    let p: ?*mut u8 = null;
    return p;
}

fn accept_nullable_const_pointer_null() -> ?*const u8 {
    let p: ?*const u8 = null;
    return p;
}

fn accept_nullable_c_void_pointer_null() -> ?*mut c_void {
    let p: ?*mut c_void = null;
    return p;
}

fn reject_non_null_mut_pointer_null() -> *mut u8 {
    // EXPECT_ERROR: E_NULL_NON_NULL_POINTER
    let p: *mut u8 = null;
    return p;
}

fn reject_non_null_const_pointer_null() -> *const u8 {
    // EXPECT_ERROR: E_NULL_NON_NULL_POINTER
    let p: *const u8 = null;
    return p;
}

fn reject_non_null_c_void_pointer_null() -> *mut c_void {
    // EXPECT_ERROR: E_NULL_NON_NULL_POINTER
    let p: *mut c_void = null;
    return p;
}
