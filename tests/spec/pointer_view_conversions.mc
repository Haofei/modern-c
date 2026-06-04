// SPEC: section=9,10,25
// SPEC: milestone=pointer-view-conversions
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_NO_IMPLICIT_POINTER_CONVERSION

fn accept_same_mut_pointer(p: *mut u32) -> *mut u32 {
    let q: *mut u32 = p;
    return q;
}

fn accept_same_const_pointer(p: *const u32) -> *const u32 {
    let q: *const u32 = p;
    return q;
}

fn accept_same_mut_raw_many(p: [*]mut u32) -> [*]mut u32 {
    let q: [*]mut u32 = p;
    return q;
}

fn accept_same_const_raw_many(p: [*]const u32) -> [*]const u32 {
    let q: [*]const u32 = p;
    return q;
}

fn accept_same_mut_slice(xs: []mut u32) -> []mut u32 {
    let ys: []mut u32 = xs;
    return ys;
}

fn accept_same_const_slice(xs: []const u32) -> []const u32 {
    let ys: []const u32 = xs;
    return ys;
}

fn accept_nullable_same_pointer(maybe: ?*mut u32) -> ?*mut u32 {
    let q: ?*mut u32 = maybe;
    return q;
}

fn accept_nullable_null() -> ?*const u32 {
    let q: ?*const u32 = null;
    return q;
}

fn reject_const_to_mut_pointer(p: *const u32) -> *mut u32 {
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    let q: *mut u32 = p;
    return q;
}

fn reject_mut_to_const_pointer(p: *mut u32) -> *const u32 {
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    let q: *const u32 = p;
    return q;
}

fn reject_mut_to_const_raw_many(p: [*]mut u32) -> [*]const u32 {
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    let q: [*]const u32 = p;
    return q;
}

fn reject_mut_to_const_slice(xs: []mut u32) -> []const u32 {
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    let ys: []const u32 = xs;
    return ys;
}

fn reject_pointer_element_type_mismatch(p: *mut u8) -> *mut u16 {
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    let q: *mut u16 = p;
    return q;
}

fn reject_raw_many_element_type_mismatch(p: [*]const u8) -> [*]const u16 {
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    let q: [*]const u16 = p;
    return q;
}

fn reject_slice_element_type_mismatch(xs: []mut u8) -> []mut u16 {
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    let ys: []mut u16 = xs;
    return ys;
}

fn reject_nonnull_to_nullable_pointer(p: *mut u32) -> ?*mut u32 {
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    let q: ?*mut u32 = p;
    return q;
}

fn reject_nullable_to_nonnull_pointer(maybe: ?*mut u32) -> *mut u32 {
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    let q: *mut u32 = maybe;
    return q;
}

fn reject_direct_return_mut_to_const_pointer(p: *mut u32) -> *const u32 {
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    return p;
}

fn reject_direct_return_element_mismatch(p: *mut u8) -> *mut u16 {
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    return p;
}

fn reject_direct_return_nullable_to_nonnull(maybe: ?*mut u32) -> *mut u32 {
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    return maybe;
}
