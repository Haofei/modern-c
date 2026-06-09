fn pointer_equality(a: *mut u8, b: *mut u8) -> bool {
    return a == b;
}

fn pointer_const_equality(a: *mut u8, b: *const u8) -> bool {
    return a == b;
}

fn nullable_pointer_equality(a: ?*mut u8, b: *mut u8) -> bool {
    return a != b;
}

fn pointer_null_comparison(p: *mut u8) -> bool {
    return p != null;
}

fn c_void_pointer_equality(a: *mut c_void, b: *mut c_void) -> bool {
    return a == b;
}
