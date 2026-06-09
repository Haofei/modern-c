extern fn consume_nullable_mut_pointer(p: ?*mut u8) -> void;
extern fn consume_nullable_c_void_pointer(p: ?*mut c_void) -> void;

fn nullable_mut_pointer_null() -> ?*mut u8 {
    let p: ?*mut u8 = null;
    return p;
}

fn nullable_const_pointer_null() -> ?*const u8 {
    let p: ?*const u8 = null;
    return p;
}

fn nullable_c_void_pointer_null() -> ?*mut c_void {
    let p: ?*mut c_void = null;
    return p;
}

fn non_null_to_nullable_return(p: *mut u8) -> ?*mut u8 {
    return p;
}

fn non_null_to_nullable_local(p: *mut u8) -> ?*mut u8 {
    let maybe: ?*mut u8 = p;
    return maybe;
}

fn non_null_to_nullable_assignment(p: *mut u8) -> ?*mut u8 {
    var maybe: ?*mut u8 = null;
    maybe = p;
    return maybe;
}

fn non_null_to_nullable_argument(p: *mut u8) -> void {
    consume_nullable_mut_pointer(p);
}

fn non_null_c_void_to_nullable(p: *mut c_void) -> ?*mut c_void {
    consume_nullable_c_void_pointer(p);
    return p;
}
