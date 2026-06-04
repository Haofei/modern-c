// SPEC: section=3,5
// SPEC: milestone=return-type-checking
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_RETURN_TYPE_MISMATCH,E_RETURN_REQUIRES_VALUE,E_RETURN_MISSING,E_INTEGER_LITERAL_OUT_OF_RANGE,E_NULL_NON_NULL_POINTER,E_ARRAY_TO_POINTER_DECAY

extern fn get_count() -> u32;

fn returns_u32() -> u32 {
    return 1;
}

fn accept_same_return(a: u32) -> u32 {
    return a;
}

fn accept_call_return_type() -> u32 {
    return returns_u32();
}

fn accept_extern_call_return_type() -> u32 {
    return get_count();
}

fn accept_context_integer_literal() -> u8 {
    return 255;
}

fn reject_empty_return_from_typed() -> u32 {
    // EXPECT_ERROR: E_RETURN_REQUIRES_VALUE
    return;
}

fn reject_missing_final_return() -> u32 {
    // EXPECT_ERROR: E_RETURN_MISSING
    let code: u32 = 0;
}

fn reject_non_exhaustive_switch_return(n: u32) -> u32 {
    // EXPECT_ERROR: E_RETURN_MISSING
    switch n {
        0 => { return 0; },
        1 => { return 1; },
    }
}

fn reject_widening_return(a: u32) -> u64 {
    // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
    return a;
}

fn reject_bool_return(flag: bool) -> u32 {
    // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
    return flag;
}

fn reject_call_return_type() -> bool {
    // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
    return returns_u32();
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
