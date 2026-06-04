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
