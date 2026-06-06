// SPEC: section=10
// SPEC: milestone=nullability
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_NULL_NON_NULL_POINTER,E_NULL_REQUIRES_TARGET,E_NO_IMPLICIT_POINTER_CONVERSION

extern fn consume_nullable_mut_pointer(p: ?*mut u8) -> void;
extern fn consume_nullable_c_void_pointer(p: ?*mut c_void) -> void;

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

fn accept_non_null_to_nullable_return(p: *mut u8) -> ?*mut u8 {
    return p;
}

fn accept_non_null_to_nullable_local(p: *mut u8) -> ?*mut u8 {
    let maybe: ?*mut u8 = p;
    return maybe;
}

fn accept_non_null_to_nullable_assignment(p: *mut u8) -> ?*mut u8 {
    var maybe: ?*mut u8 = null;
    maybe = p;
    return maybe;
}

fn accept_non_null_to_nullable_argument(p: *mut u8) -> void {
    consume_nullable_mut_pointer(p);
}

fn accept_non_null_c_void_to_nullable(p: *mut c_void) -> ?*mut c_void {
    consume_nullable_c_void_pointer(p);
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

fn reject_inferred_null_local() -> void {
    // EXPECT_ERROR: E_NULL_REQUIRES_TARGET
    let p = null;
}

fn reject_grouped_inferred_null_local() -> void {
    // EXPECT_ERROR: E_NULL_REQUIRES_TARGET
    var p = (null);
}

fn reject_nullable_to_non_null_return(maybe: ?*mut u8) -> *mut u8 {
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    return maybe;
}

fn reject_mut_to_const_nullable(p: *mut u8) -> ?*const u8 {
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    return p;
}
