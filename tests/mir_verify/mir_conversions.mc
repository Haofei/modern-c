extern fn make_u32() -> u32;
extern fn make_mut_u8_pointer() -> *mut u8;
extern fn make_c_void_pointer() -> *mut c_void;
extern fn takes_u32(value: u32) -> void;
extern fn takes_mut_pointer(value: *mut u8) -> void;
extern fn takes_c_void_pointer(value: *mut c_void) -> void;
extern struct Packet {
    value: u32,
    ptr: *mut u8,
}

fn accept_matching_return() -> u32 {
    return make_u32();
}

fn reject_return_type() -> i32 {
    return make_u32();
}

fn reject_local_initializer() -> void {
    let value: i32 = make_u32();
}

fn reject_assignment() -> void {
    var value: i32 = 0;
    value = make_u32();
}

fn accept_nonnull_to_nullable(p: *mut u8) -> ?*mut u8 {
    return p;
}

fn accept_return_pointer_const_narrow(p: *mut u8) -> *const u8 {
    return p;
}

fn reject_return_pointer_element_conversion(p: *mut u8) -> *mut u16 {
    return p;
}

fn reject_return_c_void_conversion(p: *mut c_void) -> *mut u8 {
    return p;
}

fn accept_initializer_pointer_const_narrow(p: *mut u8) -> void {
    let q: *const u8 = p;
}

fn reject_initializer_pointer_element_conversion(p: *mut u8) -> void {
    let q: *mut u16 = p;
}

fn reject_initializer_c_void_conversion(p: *mut u8) -> void {
    let q: *mut c_void = p;
}

fn reject_nullable_initializer_pointer_conversion(p: *mut u8) -> void {
    let q: ?*const u8 = p;
}

fn reject_call_argument_type(flag: bool) -> void {
    takes_u32(flag);
}

fn reject_call_argument_pointer(p: *const u8) -> void {
    takes_mut_pointer(p);
}

fn reject_call_argument_c_void(p: *mut u8) -> void {
    takes_c_void_pointer(p);
}

fn reject_assert_condition_type(value: u32) -> void {
    assert(value);
}

fn reject_while_condition_type(value: u32) -> void {
    while value {
        break;
    }
}

fn reject_for_base_type(value: u32) -> void {
    for x in value {
    }
}

fn reject_index_base_type(value: u32, index: usize) -> u8 {
    return value[index];
}

fn reject_index_operand_type(values: []const u8, flag: bool) -> u8 {
    return values[flag];
}

fn reject_direct_call_return_pointer_element() -> *mut u16 {
    return make_mut_u8_pointer();
}

fn reject_direct_call_return_c_void() -> *mut u8 {
    return make_c_void_pointer();
}

fn reject_member_assignment_pointer_conversion(p: *const u8) -> void {
    var packet: Packet = uninit;
    packet.ptr = p;
}

fn reject_deref_assignment_type(p: *mut u32, flag: bool) -> void {
    p.* = flag;
}

fn reject_index_assignment_pointer(xs: []mut *mut u8, p: *const u8) -> void {
    xs[0] = p;
}

fn reject_cast_return_type() -> u32 {
    return make_u32() as i32;
}

fn reject_cast_local_initializer() -> void {
    let value: u32 = make_u32() as i32;
}

fn reject_cast_assignment() -> void {
    var value: u32 = 0;
    value = make_u32() as i32;
}

fn reject_cast_call_argument() -> void {
    takes_u32(make_u32() as i32);
}

fn reject_cast_nullable_to_nonnull(maybe: ?*mut u8) -> *mut u8 {
    return maybe as ?*mut u8;
}
