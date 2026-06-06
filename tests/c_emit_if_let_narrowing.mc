extern fn make_nullable_pointer() -> ?*mut u8;
extern fn make_result_u32() -> Result<u32, Error>;
extern fn make_result_err_pointer() -> Result<u32, *mut u8>;

fn optional_pointer(maybe: ?*mut u8) -> u32 {
    if let p = maybe {
        return 1;
    }
    return 0;
}

fn optional_pointer_binding_type(maybe: ?*mut u8, fallback: *mut u8) -> *mut u8 {
    if let p = maybe {
        return p;
    }
    return fallback;
}

fn direct_call_optional_pointer_binding_type(fallback: *mut u8) -> *mut u8 {
    if let p = make_nullable_pointer() {
        return p;
    }
    return fallback;
}

fn result_ok(result: Result<u32, Error>) -> u32 {
    if let ok(v) = result {
        return 1;
    }
    return 0;
}

fn direct_call_result_ok_binding_type() -> u32 {
    if let ok(v) = make_result_u32() {
        return v;
    }
    return 0;
}

fn grouped_direct_call_result_ok_binding_type() -> u32 {
    if let ok(v) = (make_result_u32()) {
        return v;
    }
    return 0;
}

fn result_err(result: Result<u32, Error>) -> u32 {
    if let err(e) = result {
        return 1;
    }
    return 0;
}

fn switch_result_ok_binding_type(result: Result<u32, Error>) -> u32 {
    switch result {
        ok(v) => { return v; },
        _ => { return 0; },
    }
}
