// SPEC: section=24.1
// SPEC: milestone=c-abi-interop
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_DUPLICATE_BACKEND_NAME

#[backend_name("mc_fixture_collision")]
fn first_backend_name() -> u32 {
    return 1;
}

#[backend_name("mc_fixture_collision")]
fn second_backend_name() -> u32 { // EXPECT_ERROR: E_DUPLICATE_BACKEND_NAME
    return 2;
}
