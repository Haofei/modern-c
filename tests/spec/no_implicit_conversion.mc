// SPEC: section=3,5
// SPEC: milestone=no-implicit-conversion
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_NO_IMPLICIT_CONVERSION

fn accept_context_typed_integer_literal() -> u32 {
    let x: u32 = 10;
    return x;
}

fn accept_same_width_local_initializer(a: u32) -> u32 {
    let x: u32 = a;
    return x;
}

fn reject_runtime_integer_widening(a: u32) -> u64 {
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    let widened: u64 = a;
    return widened;
}

fn reject_bool_from_integer(a: u32) -> bool {
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    let flag: bool = a;
    return flag;
}

fn reject_integer_from_bool(flag: bool) -> u32 {
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    let x: u32 = flag;
    return x;
}

fn reject_implicit_wrap_from_checked(a: u32) -> wrap<u32> {
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    let x: wrap<u32> = a;
    return x;
}
