extern fn make_ptr() -> *mut u8;
extern fn make_const_ptr() -> *const u8;
extern fn make_ptr_from(seed: u32) -> *mut u8;
extern fn seed() -> u32;
extern fn consume_ptr(p: *mut u8) -> void;

fn extern_nonnull_return() -> *mut u8 {
    return make_ptr();
}

fn extern_nonnull_const_return() -> *const u8 {
    return make_const_ptr();
}

fn extern_nonnull_typed_local() -> *mut u8 {
    let p: *mut u8 = make_ptr();
    return p;
}

fn extern_nonnull_inferred_local() -> *mut u8 {
    let p = make_ptr();
    return p;
}

fn extern_nonnull_assignment(fallback: *mut u8) -> *mut u8 {
    var p: *mut u8 = fallback;
    p = make_ptr();
    return p;
}

fn extern_nonnull_call_arg() -> void {
    consume_ptr(make_ptr_from(seed()));
}
