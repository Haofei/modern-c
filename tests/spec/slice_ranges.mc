// SPEC: section=9
// SPEC: milestone=slice-ranges
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_INDEX_BASE_NOT_ARRAY_OR_SLICE,E_INDEX_NOT_USIZE

fn accept_slice_range_from_slice(buf: []mut u8, n: usize) -> u8 {
    let s: []mut u8 = buf[0..n];
    return s[0];
}

fn accept_slice_range_from_array(n: usize) -> u8 {
    var buf: [4]u8 = uninit;
    buf[0] = 7;
    let s: []mut u8 = buf[0..n];
    return s[0];
}

fn reject_slice_range_non_indexable(n: usize) -> []mut u8 {
    var x: u32 = 1;
    // EXPECT_ERROR: E_INDEX_BASE_NOT_ARRAY_OR_SLICE
    return x[0..n];
}

fn reject_slice_range_non_usize_bound(buf: []mut u8) -> []mut u8 {
    // EXPECT_ERROR: E_INDEX_NOT_USIZE
    return buf[0..true];
}
