// SPEC: section=9,25
// SPEC: milestone=no-array-decay
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_ARRAY_TO_POINTER_DECAY,E_USE_BEFORE_INIT

extern fn consume_pointer(p: *mut u8) -> void;

fn accept_array_element_address() -> void {
    var buf: [4]u8 = uninit;
    consume_pointer(&buf[0]);
}

fn reject_array_to_single_pointer() -> *mut u8 {
    var buf: [4]u8 = uninit;
    // EXPECT_ERROR: E_USE_BEFORE_INIT
    // EXPECT_ERROR: E_ARRAY_TO_POINTER_DECAY
    let p: *mut u8 = buf;
    return p;
}

fn reject_array_to_raw_many_pointer() -> [*]mut u8 {
    var buf: [4]u8 = uninit;
    // EXPECT_ERROR: E_USE_BEFORE_INIT
    // EXPECT_ERROR: E_ARRAY_TO_POINTER_DECAY
    let p: [*]mut u8 = buf;
    return p;
}

fn reject_array_to_slice() -> []mut u8 {
    var buf: [4]u8 = uninit;
    // EXPECT_ERROR: E_USE_BEFORE_INIT
    // EXPECT_ERROR: E_ARRAY_TO_POINTER_DECAY
    let s: []mut u8 = buf;
    return s;
}
