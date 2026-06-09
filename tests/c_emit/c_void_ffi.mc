extern "C" fn memcpy(dst: *mut c_void, src: *const c_void, n: usize) -> *mut c_void;
extern "C" fn takes_c_void(handle: *mut c_void) -> void;
extern fn make_nullable_c_void_pointer() -> ?*mut c_void;

fn accept_c_void_ffi(dst: *mut c_void, src: *const c_void, n: usize) -> *mut c_void {
    return memcpy(dst, src, n);
}

fn accept_c_void_comparison(a: *mut c_void, b: *mut c_void) -> bool {
    return a == b;
}

fn pass_c_void(handle: *mut c_void) -> void {
    takes_c_void(handle);
}

fn accept_nullable_c_void_passthrough(handle: ?*mut c_void) -> ?*mut c_void {
    return handle;
}

fn accept_nullable_c_void_call() -> ?*mut c_void {
    return make_nullable_c_void_pointer();
}

fn accept_nullable_c_void_try(handle: ?*mut c_void) -> *mut c_void {
    return handle?;
}
