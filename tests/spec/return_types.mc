// SPEC: section=3,5
// SPEC: milestone=return-type-checking
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_RETURN_TYPE_MISMATCH,E_INTEGER_LITERAL_OUT_OF_RANGE,E_NULL_NON_NULL_POINTER,E_ARRAY_TO_POINTER_DECAY

fn accept_same_return(a: u32) -> u32 {
    return a;
}

fn accept_context_integer_literal() -> u8 {
    return 255;
}

fn reject_widening_return(a: u32) -> u64 {
    // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
    return a;
}

fn reject_bool_return(flag: bool) -> u32 {
    // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
    return flag;
}

fn reject_out_of_range_literal_return() -> u8 {
    // EXPECT_ERROR: E_INTEGER_LITERAL_OUT_OF_RANGE
    return 256;
}

fn reject_null_non_null_pointer_return() -> *mut u8 {
    // EXPECT_ERROR: E_NULL_NON_NULL_POINTER
    return null;
}

fn reject_array_pointer_decay_return() -> *mut u8 {
    var buf: [4]u8 = uninit;
    // EXPECT_ERROR: E_ARRAY_TO_POINTER_DECAY
    return buf;
}
