extern fn make_mut_u32_pointer() -> *mut u32;

fn same_mut_pointer(p: *mut u32) -> *mut u32 {
    let q: *mut u32 = p;
    return q;
}

fn same_const_pointer(p: *const u32) -> *const u32 {
    let q: *const u32 = p;
    return q;
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

fn nullable_same_pointer(maybe: ?*mut u32) -> ?*mut u32 {
    let q: ?*mut u32 = maybe;
    return q;
}

fn nullable_null() -> ?*const u32 {
    let q: ?*const u32 = null;
    return q;
}

fn direct_call_same_pointer() -> *mut u32 {
    return make_mut_u32_pointer();
}

fn nonnull_to_nullable_pointer(p: *mut u32) -> ?*mut u32 {
    let q: ?*mut u32 = p;
    return q;
}
