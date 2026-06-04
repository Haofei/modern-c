// SPEC: section=9,25
// SPEC: milestone=pointer-view-conversions
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_DISCARD_CONST_VIEW

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

fn reject_const_to_mut_pointer(p: *const u32) -> *mut u32 {
    // EXPECT_ERROR: E_DISCARD_CONST_VIEW
    let q: *mut u32 = p;
    return q;
}

fn reject_const_to_mut_raw_many(p: [*]const u32) -> [*]mut u32 {
    // EXPECT_ERROR: E_DISCARD_CONST_VIEW
    let q: [*]mut u32 = p;
    return q;
}

fn reject_const_to_mut_slice(xs: []const u32) -> []mut u32 {
    // EXPECT_ERROR: E_DISCARD_CONST_VIEW
    let ys: []mut u32 = xs;
    return ys;
}
