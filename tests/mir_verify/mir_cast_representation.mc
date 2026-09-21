struct PtrPacket {
    ptr: *mut u8,
}

extern fn make_ptr() -> *mut u8;
extern fn take_ptr(value: *mut u8) -> void;

fn cast_pointer_return() -> *mut u8 {
    return make_ptr() as *mut u8;
}

fn cast_pointer_local() -> *mut u8 {
    let p: *mut u8 = make_ptr() as *mut u8;
    return p;
}

fn cast_pointer_assignment() -> *mut u8 {
    var p: *mut u8 = make_ptr();
    p = make_ptr() as *mut u8;
    return p;
}

fn cast_pointer_call_arg() -> void {
    take_ptr(make_ptr() as *mut u8);
}

fn cast_pointer_aggregate_field() -> PtrPacket {
    return .{ .ptr = make_ptr() as *mut u8 };
}

fn cast_pointer_aggregate_element() -> [1]*mut u8 {
    return .{ make_ptr() as *mut u8 };
}
