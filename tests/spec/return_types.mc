// SPEC: section=3,5,13
// SPEC: milestone=return-type-checking
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_RETURN_TYPE_MISMATCH,E_RETURN_REQUIRES_VALUE,E_RETURN_MISSING,E_INTEGER_LITERAL_OUT_OF_RANGE,E_NULL_NON_NULL_POINTER,E_ARRAY_TO_POINTER_DECAY,E_CLOSED_ENUM_SWITCH_EXHAUSTIVE

extern fn get_count() -> u32;
global shared_count: u32 = 0;

enum TrafficLight: u8 {
    red = 0,
    yellow = 1,
    green = 2,
}

open enum OpenTrafficLight: u8 {
    red = 0,
    yellow = 1,
    green = 2,
}

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

fn accept_global_return_type() -> u32 {
    return shared_count;
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

fn accept_exhaustive_switch_return(n: u32) -> u32 {
    switch n {
        0 => { return 0; },
        _ => { return 1; },
    }
}

fn accept_result_switch_return(result: Result<u32, Error>) -> u32 {
    switch result {
        ok(v) => { return v; },
        err(e) => { return 0; },
    }
}

fn accept_closed_enum_switch_return(light: TrafficLight) -> u32 {
    switch light {
        .red => { return 0; },
        .yellow => { return 1; },
        .green => { return 2; },
    }
}

fn reject_closed_enum_switch_missing_case(light: TrafficLight) -> u32 {
    // EXPECT_ERROR: E_RETURN_MISSING
    // EXPECT_ERROR: E_CLOSED_ENUM_SWITCH_EXHAUSTIVE
    switch light {
        .red => { return 0; },
        .yellow => { return 1; },
    }
}

fn reject_closed_enum_switch_fallthrough_arm(light: TrafficLight) -> u32 {
    // EXPECT_ERROR: E_RETURN_MISSING
    switch light {
        .red => { return 0; },
        .yellow => { return 1; },
        .green => { let fallback: u32 = 2; },
    }
}

fn reject_open_enum_switch_without_wildcard(light: OpenTrafficLight) -> u32 {
    // EXPECT_ERROR: E_RETURN_MISSING
    switch light {
        .red => { return 0; },
        .yellow => { return 1; },
        .green => { return 2; },
    }
}

fn accept_open_enum_switch_with_wildcard(light: OpenTrafficLight) -> u32 {
    switch light {
        .red => { return 0; },
        .yellow => { return 1; },
        .green => { return 2; },
        _ => { return 3; },
    }
}

fn reject_exhaustive_switch_fallthrough_arm(n: u32) -> u32 {
    // EXPECT_ERROR: E_RETURN_MISSING
    switch n {
        0 => { return 0; },
        _ => { let fallback: u32 = 1; },
    }
}

fn reject_result_switch_fallthrough_arm(result: Result<u32, Error>) -> u32 {
    // EXPECT_ERROR: E_RETURN_MISSING
    switch result {
        ok(v) => { return v; },
        err(e) => { let fallback: u32 = 0; },
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

fn reject_global_return_type() -> bool {
    // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
    return shared_count;
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
