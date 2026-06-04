// SPEC: section=9
// SPEC: milestone=single-object-pointer-arithmetic
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_POINTER_ARITH_SINGLE_OBJECT

fn accept_pointer_equality(a: *mut u8, b: *mut u8) -> bool {
    return a == b;
}

fn accept_c_void_pointer_equality(a: *mut c_void, b: *mut c_void) -> bool {
    return a == b;
}

fn reject_pointer_plus_int(p: *mut u32, n: usize) -> *mut u32 {
    // EXPECT_ERROR: E_POINTER_ARITH_SINGLE_OBJECT
    return p + n;
}

fn reject_int_plus_pointer(p: *mut u32, n: usize) -> *mut u32 {
    // EXPECT_ERROR: E_POINTER_ARITH_SINGLE_OBJECT
    return n + p;
}

fn reject_pointer_minus_int(p: *const u32, n: usize) -> *const u32 {
    // EXPECT_ERROR: E_POINTER_ARITH_SINGLE_OBJECT
    return p - n;
}

fn reject_pointer_minus_pointer(a: *const u32, b: *const u32) -> usize {
    // EXPECT_ERROR: E_POINTER_ARITH_SINGLE_OBJECT
    return a - b;
}

fn reject_c_void_pointer_plus_int(p: *mut c_void, n: usize) -> *mut c_void {
    // EXPECT_ERROR: E_POINTER_ARITH_SINGLE_OBJECT
    return p + n;
}
