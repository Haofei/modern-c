extern fn make_nullable() -> ?*mut u8;

fn reject_null_local() -> *mut u8 {
    let p: *mut u8 = null;
    return p;
}

fn reject_null_assignment(fallback: *mut u8) -> *mut u8 {
    var p: *mut u8 = fallback;
    p = null;
    return p;
}

fn reject_nullable_return(maybe: ?*mut u8) -> *mut u8 {
    return maybe;
}

fn reject_nullable_call_return() -> *mut u8 {
    return make_nullable();
}

fn accept_nonnull_to_nullable(p: *mut u8) -> ?*mut u8 {
    return p;
}

fn accept_null_nullable() -> ?*mut u8 {
    return null;
}
