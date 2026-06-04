// SPEC: section=9,12
// SPEC: milestone=pointer-view-mutability
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_ASSIGN_THROUGH_CONST_VIEW,E_INDEX_BASE_NOT_ARRAY_OR_SLICE,E_NO_IMPLICIT_CONVERSION,E_NO_IMPLICIT_POINTER_CONVERSION

global shared_cell: u32 = 0;
global global_const_ptr: *const u32 = &shared_cell;
global global_mut_ptr: *mut u32 = &shared_cell;

fn accept_assign_through_mut_pointer(p: *mut u32, value: u32) -> void {
    p.* = value;
}

fn accept_assign_through_global_mut_pointer(value: u32) -> void {
    global_mut_ptr.* = value;
}

fn accept_local_shadow_global_const_pointer(global_const_ptr: *mut u32, value: u32) -> void {
    global_const_ptr.* = value;
}

fn accept_inferred_local_shadow_global_const_pointer(p: *mut u32, value: u32) -> void {
    let global_const_ptr = p;
    global_const_ptr.* = value;
}

fn reject_index_assign_through_mut_raw_many(p: [*]mut u32, value: u32) -> void {
    // EXPECT_ERROR: E_INDEX_BASE_NOT_ARRAY_OR_SLICE
    p[0] = value;
}

fn accept_assign_through_mut_slice(xs: []mut u32, i: usize, value: u32) -> void {
    xs[i] = value;
}

fn reject_assign_bool_through_mut_pointer(p: *mut u32, flag: bool) -> void {
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    p.* = flag;
}

fn reject_assign_bool_through_mut_slice(xs: []mut u32, i: usize, flag: bool) -> void {
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    xs[i] = flag;
}

fn reject_assign_bool_through_mut_array(i: usize, flag: bool) -> void {
    var xs: [4]u32 = uninit;
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    xs[i] = flag;
}

fn reject_assign_wide_integer_through_mut_pointer(p: *mut u32, value: u64) -> void {
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    p.* = value;
}

fn reject_assign_pointer_conversion_through_mut_slice(xs: []mut *mut u8, i: usize, p: *const u8) -> void {
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    xs[i] = p;
}

fn reject_assign_through_const_pointer(p: *const u32, value: u32) -> void {
    // EXPECT_ERROR: E_ASSIGN_THROUGH_CONST_VIEW
    p.* = value;
}

fn reject_assign_through_global_const_pointer(value: u32) -> void {
    // EXPECT_ERROR: E_ASSIGN_THROUGH_CONST_VIEW
    global_const_ptr.* = value;
}

fn reject_assign_through_const_raw_many(p: [*]const u32, value: u32) -> void {
    // EXPECT_ERROR: E_INDEX_BASE_NOT_ARRAY_OR_SLICE
    // EXPECT_ERROR: E_ASSIGN_THROUGH_CONST_VIEW
    p[0] = value;
}

fn reject_assign_through_const_slice(xs: []const u32, i: usize, value: u32) -> void {
    // EXPECT_ERROR: E_ASSIGN_THROUGH_CONST_VIEW
    xs[i] = value;
}

fn reject_assign_bool_through_const_slice(xs: []const u32, i: usize, flag: bool) -> void {
    // EXPECT_ERROR: E_ASSIGN_THROUGH_CONST_VIEW
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    xs[i] = flag;
}
