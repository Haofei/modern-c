extern fn maybe_ptr() -> ?*mut u8;
extern fn maybe_ptr_from(seed: u32) -> ?*mut u8;
extern fn next_seed() -> u32;
extern fn ptr_value(p: *mut u8) -> u32;
extern fn consume_nullable(p: ?*mut u8) -> void;
extern fn consume_ptr(p: *mut u8) -> void;

global saved_nullable: ?*mut u8 = null;

struct NullableBox {
    maybe: ?*mut u8,
}

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
    consume_nullable(p);
}

fn unwrap_param(maybe: ?*mut u8) -> *mut u8 {
    return maybe?;
}

fn unwrap_call() -> *mut u8 {
    return make_nonnull();
}

extern fn make_nonnull() -> *mut u8;

fn unwrap_nullable_call() -> *mut u8 {
    return maybe_ptr()?;
}

fn arg_try(maybe: ?*mut u8) -> u32 {
    return ptr_value(maybe?);
}

fn direct_arg_try() -> u32 {
    return ptr_value(maybe_ptr()?);
}

fn expr_nullable_try() -> void {
    consume_ptr(maybe_ptr()?);
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

fn unwrap_global_or_zero() -> u32 {
    if let p = saved_nullable {
        return ptr_value(p);
    }
    return 0;
}

fn unwrap_field_or_zero(box: NullableBox) -> u32 {
    if let p = box.maybe {
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
