extern fn make_result_u32() -> Result<u32, Error>;
extern fn make_result_pointer() -> Result<*mut u8, Error>;
extern fn make_result_c_void_pointer() -> Result<*mut c_void, Error>;
extern fn make_result_u16_pointer() -> Result<*mut u16, Error>;
extern fn make_result_bytes() -> Result<[2]u8, Error>;
extern fn make_nullable_mut_pointer() -> ?*mut u8;
extern fn make_nullable_c_void_pointer() -> ?*mut c_void;
extern fn takes_const_pointer(value: *const u8) -> void;

struct PointerBox {
    ptr: *const u8,
}

fn accept_result_try_payload() -> u32 {
    return make_result_u32()?;
}

fn accept_result_pointer_try_payload() -> *mut u8 {
    return make_result_pointer()?;
}

fn accept_nullable_pointer_try_payload() -> *mut u8 {
    return make_nullable_mut_pointer()?;
}

fn reject_result_try_payload() -> *mut u8 {
    return make_result_u32()?;
}

fn reject_pointer_payload_to_integer() -> u32 {
    return make_result_pointer()?;
}

fn accept_result_pointer_payload_const_narrow() -> *const u8 {
    return make_result_pointer()?;
}

fn reject_result_pointer_payload_element_conversion() -> *mut u16 {
    return make_result_pointer()?;
}

fn reject_result_c_void_payload_conversion() -> *mut u8 {
    return make_result_c_void_pointer()?;
}

fn reject_result_typed_to_c_void_payload_conversion() -> *mut c_void {
    return make_result_pointer()?;
}

fn accept_nullable_pointer_payload_const_narrow() -> *const u8 {
    return make_nullable_mut_pointer()?;
}

fn reject_nullable_c_void_payload_conversion() -> *mut u8 {
    return make_nullable_c_void_pointer()?;
}

fn accept_result_try_local_initializer_const_narrow() -> void {
    let ptr: *const u8 = make_result_pointer()?;
}

fn accept_result_try_assignment_const_narrow(fallback: *const u8) -> void {
    var ptr: *const u8 = fallback;
    ptr = make_result_pointer()?;
}

fn accept_result_try_call_arg_const_narrow() -> void {
    takes_const_pointer(make_result_pointer()?);
}

fn accept_result_try_aggregate_field_const_narrow() -> PointerBox {
    return .{ .ptr = make_result_pointer()? };
}

fn accept_cast_result_try_payload_const_narrow() -> *const u8 {
    return (make_result_pointer()? as *const u8);
}

fn accept_cast_result_try_local_initializer_const_narrow() -> void {
    let ptr: *const u8 = (make_result_pointer()? as *const u8);
}

fn accept_cast_result_try_assignment_const_narrow(fallback: *const u8) -> void {
    var ptr: *const u8 = fallback;
    ptr = (make_result_pointer()? as *const u8);
}

fn accept_cast_result_try_call_arg_const_narrow() -> void {
    takes_const_pointer(make_result_pointer()? as *const u8);
}

fn accept_cast_result_try_aggregate_field_const_narrow() -> PointerBox {
    return .{ .ptr = make_result_pointer()? as *const u8 };
}

fn reject_inferred_result_array_try_index() -> *mut u8 {
    let bytes = make_result_bytes()?;
    return bytes[0];
}

fn reject_if_let_result_array_binding() -> *mut u8 {
    if let ok(bytes) = make_result_bytes() {
        return bytes[0];
    } else {
        return make_result_pointer()?;
    }
}

fn reject_switch_result_array_binding() -> *mut u8 {
    let result = make_result_bytes();
    switch result {
        ok(bytes) => {
            return bytes[0];
        },
        err(e) => {
            return make_result_pointer()?;
        },
    }
}
