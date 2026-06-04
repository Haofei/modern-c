// SPEC: section=9,12
// SPEC: milestone=pointer-view-mutability
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_ASSIGN_THROUGH_CONST_VIEW,E_INDEX_BASE_NOT_ARRAY_OR_SLICE

fn accept_assign_through_mut_pointer(p: *mut u32, value: u32) -> void {
    p.* = value;
}

fn reject_index_assign_through_mut_raw_many(p: [*]mut u32, value: u32) -> void {
    // EXPECT_ERROR: E_INDEX_BASE_NOT_ARRAY_OR_SLICE
    p[0] = value;
}

fn accept_assign_through_mut_slice(xs: []mut u32, i: usize, value: u32) -> void {
    xs[i] = value;
}

fn reject_assign_through_const_pointer(p: *const u32, value: u32) -> void {
    // EXPECT_ERROR: E_ASSIGN_THROUGH_CONST_VIEW
    p.* = value;
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
