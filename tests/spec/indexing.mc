// SPEC: section=9
// SPEC: milestone=index-usize
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_INDEX_NOT_USIZE

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
