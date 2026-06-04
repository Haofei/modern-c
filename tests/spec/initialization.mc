// SPEC: section=12
// SPEC: milestone=local-initialization
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_LOCAL_REQUIRES_INITIALIZER

fn accept_initialized_local() -> u32 {
    var x: u32 = 1;
    return x;
}

fn accept_explicit_uninit_storage() -> u32 {
    var buf: [4096]u8 = uninit;
    return 0;
}

fn accept_maybe_uninit_storage() -> u32 {
    var x: MaybeUninit<Node> = uninit;
    return 0;
}

fn reject_uninitialized_var() -> u32 {
    // EXPECT_ERROR: E_LOCAL_REQUIRES_INITIALIZER
    var x: i32;
    return 0;
}

fn reject_uninitialized_let() -> u32 {
    // EXPECT_ERROR: E_LOCAL_REQUIRES_INITIALIZER
    let y: u32;
    return 0;
}
