// SPEC: section=2,9
// SPEC: milestone=trivial-local-address-escape
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_LOCAL_ADDRESS_ESCAPE

global shared_counter: u32 = 0;

extern struct Packet {
    value: u32,
}

fn accept_return_parameter_pointer(p: *mut u32) -> *mut u32 {
    return p;
}

fn accept_return_const_parameter_pointer(p: *const u32) -> *const u32 {
    return p;
}

fn accept_return_global_address() -> *mut u32 {
    return &shared_counter;
}

fn accept_return_parameter_pointer_alias(p: *mut u32) -> *mut u32 {
    let q: *mut u32 = p;
    return q;
}

fn accept_return_const_parameter_pointer_alias(p: *const u32) -> *const u32 {
    let q: *const u32 = p;
    return q;
}

fn accept_return_global_address_alias() -> *mut u32 {
    let p: *mut u32 = &shared_counter;
    return p;
}

fn accept_return_slice_element_address(xs: []mut u32, i: usize) -> *mut u32 {
    return &xs[i];
}

fn accept_cleared_local_pointer_alias(p: *mut u32) -> *mut u32 {
    var x: u32 = 1;
    var out: *mut u32 = &x;
    out = p;
    return out;
}

fn accept_cleared_assigned_local_pointer_alias(p: *mut u32) -> *mut u32 {
    var x: u32 = 1;
    var out: *mut u32 = p;
    out = &x;
    out = p;
    return out;
}

fn accept_copied_after_cleared_local_pointer_alias(p: *mut u32) -> *mut u32 {
    var x: u32 = 1;
    var out: *mut u32 = p;
    out = &x;
    out = p;
    let q: *mut u32 = out;
    return q;
}

fn accept_cleared_local_pointer_with_global() -> *mut u32 {
    var x: u32 = 1;
    var out: *mut u32 = &x;
    out = &shared_counter;
    return out;
}

fn accept_copied_after_cleared_local_pointer_with_global() -> *mut u32 {
    var x: u32 = 1;
    var out: *mut u32 = &x;
    out = &shared_counter;
    let q: *mut u32 = out;
    return q;
}

fn reject_return_var_local_address() -> *mut u32 {
    var x: u32 = 1;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return &x;
}

fn reject_return_let_local_address() -> *const u32 {
    let x: u32 = 1;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return &x;
}

fn reject_return_grouped_local_address() -> *mut u32 {
    var x: u32 = 1;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return &(x);
}

fn reject_return_local_field_address() -> *mut u32 {
    var packet: Packet = uninit;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return &packet.value;
}

fn reject_return_local_array_element_address(i: usize) -> *mut u32 {
    var xs: [4]u32 = uninit;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return &xs[i];
}

fn reject_return_local_pointer_to_var() -> *mut u32 {
    var x: u32 = 1;
    let p: *mut u32 = &x;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return p;
}

fn reject_return_local_pointer_to_let() -> *const u32 {
    let x: u32 = 1;
    let p: *const u32 = &x;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return p;
}

fn reject_return_grouped_local_pointer_to_var() -> *mut u32 {
    var x: u32 = 1;
    let p: *mut u32 = &x;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return (p);
}

fn reject_return_copied_local_pointer() -> *mut u32 {
    var x: u32 = 1;
    let p: *mut u32 = &x;
    let q: *mut u32 = p;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return q;
}

fn reject_return_var_pointer_initialized_local_address() -> *mut u32 {
    var x: u32 = 1;
    var p: *mut u32 = &x;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return p;
}

fn reject_return_grouped_var_pointer_initialized_local_address() -> *mut u32 {
    var x: u32 = 1;
    var p: *mut u32 = &(x);
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return (p);
}

fn reject_return_copied_var_pointer_initialized_local_address() -> *mut u32 {
    var x: u32 = 1;
    var p: *mut u32 = &x;
    let q: *mut u32 = p;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return q;
}

fn reject_return_assigned_local_pointer(fallback: *mut u32) -> *mut u32 {
    var x: u32 = 1;
    var out: *mut u32 = fallback;
    out = &x;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return out;
}

fn reject_return_assigned_grouped_local_pointer(fallback: *mut u32) -> *mut u32 {
    var x: u32 = 1;
    var out: *mut u32 = fallback;
    (out) = &x;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return out;
}

fn reject_return_assigned_grouped_address_local_pointer(fallback: *mut u32) -> *mut u32 {
    var x: u32 = 1;
    var out: *mut u32 = fallback;
    out = &(x);
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return (out);
}

fn reject_return_assigned_copied_local_pointer(fallback: *mut u32) -> *mut u32 {
    var x: u32 = 1;
    let p: *mut u32 = &x;
    var out: *mut u32 = fallback;
    out = p;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return out;
}

fn reject_return_copied_after_assigned_local_pointer(fallback: *mut u32) -> *mut u32 {
    var x: u32 = 1;
    var out: *mut u32 = fallback;
    out = &x;
    let q: *mut u32 = out;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return q;
}

fn reject_return_var_copied_after_assigned_local_pointer(fallback: *mut u32) -> *mut u32 {
    var x: u32 = 1;
    var out: *mut u32 = fallback;
    out = &x;
    var q: *mut u32 = fallback;
    q = out;
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return q;
}
