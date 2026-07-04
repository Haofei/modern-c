// SPEC: section=3,8,9,10,25
// SPEC: milestone=assignment-values-no-implicit-conversion
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_NO_IMPLICIT_CONVERSION,E_NULL_NON_NULL_POINTER,E_ARRAY_TO_POINTER_DECAY,E_NO_IMPLICIT_POINTER_CONVERSION,E_CALL_ARG_COUNT

global shared_value: u32 = 0;
global copied_value: u32 = shared_value;

fn make_bool() -> bool {
    return true;
}

fn takes_u32(value: u32) -> u32 {
    return value;
}

fn takes_mut_u8_pointer(p: *mut u8) -> *mut u8 {
    return p;
}

fn accept_same_integer_assignment(value: u32) -> u32 {
    var x: u32 = 0;
    x = value;
    return x;
}

fn accept_call_argument_type(value: u32) -> u32 {
    return takes_u32(value);
}

fn accept_same_bool_assignment(flag: bool) -> bool {
    var x: bool = false;
    x = flag;
    return x;
}

fn accept_nullable_null_assignment() -> ?*mut u8 {
    var p: ?*mut u8 = null;
    p = null;
    return p;
}

fn accept_same_pointer_assignment(p: *mut u32) -> *mut u32 {
    var q: *mut u32 = p;
    q = p;
    return q;
}

fn accept_global_assignment(value: u32) -> u32 {
    shared_value = value;
    return shared_value;
}

fn accept_local_shadows_global_assignment() -> bool {
    var shared_value: bool = false;
    shared_value = true;
    return shared_value;
}

fn reject_integer_widening_assignment(value: u32) -> u64 {
    var x: u64 = 0;
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    x = value;
    return x;
}

fn reject_integer_narrowing_assignment(value: u64) -> u32 {
    var x: u32 = 0;
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    x = value;
    return x;
}

fn reject_bool_to_integer_assignment(flag: bool) -> u32 {
    var x: u32 = 0;
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    x = flag;
    return x;
}

fn reject_integer_to_bool_assignment(value: u32) -> bool {
    var flag: bool = false;
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    flag = value;
    return flag;
}

fn reject_call_argument_bool_to_integer(flag: bool) -> u32 {
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    return takes_u32(flag);
}

fn reject_call_argument_pointer_conversion(p: *const u8, fallback: *mut u8) -> *mut u8 {
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    return takes_mut_u8_pointer(p);
}

fn reject_call_missing_argument() -> u32 {
    // EXPECT_ERROR: E_CALL_ARG_COUNT
    return takes_u32();
}

fn reject_call_extra_argument(value: u32) -> u32 {
    // EXPECT_ERROR: E_CALL_ARG_COUNT
    return takes_u32(value, value);
}

fn reject_call_assignment_value_type() -> u32 {
    var x: u32 = 0;
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    x = make_bool();
    return x;
}

fn reject_global_assignment_value_type(flag: bool) -> u32 {
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    shared_value = flag;
    return shared_value;
}

fn reject_null_to_nonnull_pointer_assignment() -> *mut u8 {
    var p: *mut u8 = uninit;
    // EXPECT_ERROR: E_NULL_NON_NULL_POINTER
    p = null;
    return p;
}

fn reject_array_to_single_pointer_assignment() -> *mut u8 {
    var buf: [4]u8 = .{ 0, 0, 0, 0 };
    var p: *mut u8 = &buf[0];
    // EXPECT_ERROR: E_ARRAY_TO_POINTER_DECAY
    p = buf;
    return p;
}

fn reject_array_to_raw_many_pointer_assignment() -> [*]mut u8 {
    var buf: [4]u8 = uninit;
    var p: [*]mut u8 = uninit;
    // EXPECT_ERROR: E_USE_BEFORE_INIT
    // EXPECT_ERROR: E_ARRAY_TO_POINTER_DECAY
    p = buf;
    return p;
}

fn reject_array_to_slice_assignment() -> []mut u8 {
    var buf: [4]u8 = uninit;
    var xs: []mut u8 = uninit;
    // EXPECT_ERROR: E_USE_BEFORE_INIT
    // EXPECT_ERROR: E_ARRAY_TO_POINTER_DECAY
    xs = buf;
    return xs;
}

fn reject_const_to_mut_pointer_assignment(p: *const u32, q: *mut u32) -> *mut u32 {
    var out: *mut u32 = q;
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    out = p;
    return out;
}

// mut -> const at an assignment: an allowed const-narrow (language gap G30; a `*mut T` and a
// `*const T` share the identical plain-pointer repr). The reverse assignment stays rejected
// (see reject_const_to_mut_pointer_assignment above).
fn accept_mut_to_const_pointer_assignment(p: *mut u32, q: *const u32) -> *const u32 {
    var out: *const u32 = q;
    out = p;
    return out;
}

fn reject_nullable_to_nonnull_pointer_assignment(maybe: ?*mut u32, fallback: *mut u32) -> *mut u32 {
    var out: *mut u32 = fallback;
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    out = maybe;
    return out;
}

fn reject_pointer_element_type_assignment(p: *mut u8, q: *mut u16) -> *mut u16 {
    var out: *mut u16 = q;
    // EXPECT_ERROR: E_NO_IMPLICIT_POINTER_CONVERSION
    out = p;
    return out;
}
