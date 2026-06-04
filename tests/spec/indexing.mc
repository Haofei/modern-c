// SPEC: section=9
// SPEC: milestone=index-usize
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_INDEX_NOT_USIZE,E_INDEX_BASE_NOT_ARRAY_OR_SLICE

fn accept_slice_usize_index(buf: []const u8, i: usize) -> u8 {
    return buf[i];
}

fn accept_slice_literal_index(buf: []const u8) -> u8 {
    return buf[0];
}

fn accept_array_usize_index(buf: [4]u8, i: usize) -> u8 {
    return buf[i];
}

fn reject_slice_u32_index(buf: []const u8, i: u32) -> u8 {
    // EXPECT_ERROR: E_INDEX_NOT_USIZE
    return buf[i];
}

fn reject_slice_wrap_index(buf: []const u8, i: wrap<usize>) -> u8 {
    // EXPECT_ERROR: E_INDEX_NOT_USIZE
    return buf[i];
}

fn reject_slice_bool_index(buf: []const u8, flag: bool) -> u8 {
    // EXPECT_ERROR: E_INDEX_NOT_USIZE
    return buf[flag];
}

fn reject_single_pointer_index(p: *mut u8, i: usize) -> u8 {
    // EXPECT_ERROR: E_INDEX_BASE_NOT_ARRAY_OR_SLICE
    return p[i];
}

fn reject_raw_many_index(p: [*]mut u8, i: usize) -> u8 {
    // EXPECT_ERROR: E_INDEX_BASE_NOT_ARRAY_OR_SLICE
    return p[i];
}

fn reject_raw_many_c_void_index(p: [*]mut c_void, i: usize) -> c_void {
    // EXPECT_ERROR: E_INDEX_BASE_NOT_ARRAY_OR_SLICE
    return p[i];
}

fn reject_integer_index(n: u32, i: usize) -> u8 {
    // EXPECT_ERROR: E_INDEX_BASE_NOT_ARRAY_OR_SLICE
    return n[i];
}

fn reject_nullable_pointer_index(maybe: ?*mut u8, i: usize) -> u8 {
    // EXPECT_ERROR: E_INDEX_BASE_NOT_ARRAY_OR_SLICE
    return maybe[i];
}
