fn same_mut_pointer(p: *mut u32) -> *mut u32 {
    let q: *mut u32 = p;
    return q;
}

fn same_const_pointer(p: *const u32) -> *const u32 {
    let q: *const u32 = p;
    return q;
}

fn assign_through_mut_pointer(p: *mut u32, value: u32) -> void {
    p.* = value;
}

fn compare_mut_const_pointer(a: *mut u32, b: *const u32) -> bool {
    return a == b;
}

fn compare_nullable_pointer(a: ?*mut u32, b: *mut u32) -> bool {
    return a != b;
}

fn compare_pointer_null(p: *mut u32) -> bool {
    return p != null;
}

fn same_mut_raw_many(p: [*]mut u32) -> [*]mut u32 {
    let q: [*]mut u32 = p;
    return q;
}

fn same_const_raw_many(p: [*]const u32) -> [*]const u32 {
    let q: [*]const u32 = p;
    return q;
}

fn same_mut_slice(xs: []mut u32) -> []mut u32 {
    let ys: []mut u32 = xs;
    return ys;
}

fn same_const_slice(xs: []const u32) -> []const u32 {
    let ys: []const u32 = xs;
    return ys;
}

fn assign_through_mut_slice(xs: []mut u32, i: usize, value: u32) -> void {
    xs[i] = value;
}
