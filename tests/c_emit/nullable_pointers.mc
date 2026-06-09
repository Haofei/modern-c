extern fn maybe_ptr() -> ?*mut u8;
extern fn maybe_ptr_from(seed: u32) -> ?*mut u8;
extern fn next_seed() -> u32;
extern fn ptr_value(p: *mut u8) -> u32;
extern fn consume_nullable_mut(p: ?*mut u8) -> void;
extern fn consume_nullable_c_void(p: ?*mut c_void) -> void;

fn nullable_null() -> ?*mut u8 {
    return null;
}

fn nullable_from_nonnull_return(p: *mut u8) -> ?*mut u8 {
    return p;
}

fn nullable_from_nonnull_local(p: *mut u8) -> ?*mut u8 {
    let maybe: ?*mut u8 = p;
    return maybe;
}

fn nullable_from_nonnull_assignment(p: *mut u8) -> ?*mut u8 {
    var maybe: ?*mut u8 = null;
    maybe = p;
    return maybe;
}

fn nullable_from_nonnull_arg(p: *mut u8) -> void {
    consume_nullable_mut(p);
}

fn nullable_c_void_from_nonnull(p: *mut c_void) -> ?*mut c_void {
    consume_nullable_c_void(p);
    return p;
}

fn unwrap_or(maybe: ?*mut u8, fallback: *mut u8) -> *mut u8 {
    if let p = maybe {
        return p;
    } else {
        return fallback;
    }
}

fn unwrap_call_or_zero() -> u32 {
    if let p = maybe_ptr() {
        return ptr_value(p);
    }
    return 0;
}

fn unwrap_call_seed_or_zero() -> u32 {
    if let p = maybe_ptr_from(next_seed()) {
        return ptr_value(p);
    }
    return 0;
}

fn nullable_switch(maybe: ?*mut u8) -> u32 {
    switch maybe {
        p => {
            return ptr_value(p);
        },
        _ => {
            return 0;
        },
    }
}

fn nullable_switch_call_seed() -> u32 {
    switch maybe_ptr_from(next_seed()) {
        p => {
            return ptr_value(p);
        },
        _ => {
            return 0;
        },
    }
}
