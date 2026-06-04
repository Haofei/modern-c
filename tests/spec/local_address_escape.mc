// SPEC: section=2,9
// SPEC: milestone=trivial-local-address-escape
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_LOCAL_ADDRESS_ESCAPE

global shared_counter: u32 = 0;

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
