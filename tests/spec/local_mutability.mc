// SPEC: section=8,12
// SPEC: milestone=local-mutability
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_ASSIGN_TO_IMMUTABLE_LOCAL,E_DUPLICATE_PARAMETER

fn accept_assign_to_var() -> u32 {
    var x: u32 = 1;
    x = 2;
    return x;
}

fn reject_assign_to_let() -> u32 {
    let x: u32 = 1;
    // EXPECT_ERROR: E_ASSIGN_TO_IMMUTABLE_LOCAL
    x = 2;
    return x;
}

fn reject_assign_to_param(x: u32) -> u32 {
    // EXPECT_ERROR: E_ASSIGN_TO_IMMUTABLE_LOCAL
    x = 2;
    return x;
}

// EXPECT_ERROR: E_DUPLICATE_PARAMETER
fn reject_duplicate_parameter(x: u32, x: bool) -> u32 {
    return x;
}
