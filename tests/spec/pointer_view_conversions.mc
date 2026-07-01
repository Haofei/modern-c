// SPEC: section=9,10,25
// SPEC: milestone=pointer-view-conversions
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_NO_IMPLICIT_POINTER_CONVERSION

extern fn make_mut_u8_pointer() -> *mut u8;
extern fn make_mut_u32_pointer() -> *mut u32;
extern fn takes_mut_u16_pointer(p: *mut u16) -> void;

global shared_byte: u8 = 0;

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

fn accept_direct_call_same_pointer() -> *mut u32 {
    return make_mut_u32_pointer();
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

// A `[]mut T` -> `[]const T` slice const-narrowing IS allowed implicitly (language gap G12
// #3): the fat pointer is layout-identical, only the pointee's constness differs, so it is a
// safe no-op coercion. This is scoped to slices — the `*mut`/`[*]mut` reject cases above still
// hold (a single-object / raw-many const-narrow stays explicit).
fn accept_mut_to_const_slice(xs: []mut u32) -> []const u32 {
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

fn accept_nonnull_to_nullable_pointer(p: *mut u32) -> ?*mut u32 {
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

fn reject_direct_call_return_element_mismatch() -> *mut u16 {
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    return make_mut_u8_pointer();
}

fn reject_direct_call_initializer_element_mismatch() -> *mut u16 {
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    let q: *mut u16 = make_mut_u8_pointer();
    return q;
}

fn reject_direct_call_assignment_element_mismatch(fallback: *mut u16) -> *mut u16 {
    var q: *mut u16 = fallback;
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    q = make_mut_u8_pointer();
    return q;
}

fn reject_direct_call_argument_element_mismatch() -> void {
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    takes_mut_u16_pointer(make_mut_u8_pointer());
}

fn reject_cast_result_return_mut_to_const_pointer(p: *mut u8) -> *const u8 {
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    return p as *mut u8;
}

fn reject_cast_result_initializer_element_mismatch(p: *mut u8) -> *mut u16 {
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    let q: *mut u16 = p as *mut u8;
    return q;
}

fn reject_cast_result_argument_element_mismatch(p: *mut u8) -> void {
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    takes_mut_u16_pointer(p as *mut u8);
}

fn reject_address_of_element_mismatch_initializer() -> *mut u16 {
    var buf: [4]u8 = uninit;
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    let q: *mut u16 = &buf[0];
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return q;
}

fn reject_address_of_immutable_local_to_mut_pointer(fallback: *mut u32) -> *mut u32 {
    let x: u32 = 1;
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    let q: *mut u32 = &x;
    return fallback;
}

fn reject_address_of_element_mismatch_assignment(fallback: *mut u16) -> *mut u16 {
    var buf: [4]u8 = uninit;
    var q: *mut u16 = fallback;
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    q = &buf[0];
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return q;
}

fn reject_address_of_element_mismatch_argument() -> void {
    var buf: [4]u8 = uninit;
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    takes_mut_u16_pointer(&buf[0]);
}

fn reject_address_of_global_element_mismatch() -> *mut u16 {
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    let q: *mut u16 = &shared_byte;
    return q;
}

fn reject_address_of_global_return_element_mismatch() -> *mut u16 {
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    return &shared_byte;
}
