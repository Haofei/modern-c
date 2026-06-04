// SPEC: section=11
// SPEC: milestone=if-let-narrowing
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_IF_LET_OPTIONAL_REQUIRED,E_IF_LET_RESULT_REQUIRED,E_IF_LET_RESULT_TAG,E_IF_LET_NARROW_PATTERN,E_RETURN_TYPE_MISMATCH,E_SWITCH_RESULT_TAG,E_SWITCH_RESULT_REQUIRED,E_SWITCH_MULTI_BINDING_ARM

extern fn make_nullable_pointer() -> ?*mut u8;
extern fn make_result_u32() -> Result<u32, Error>;
extern fn make_result_err_pointer() -> Result<u32, *mut u8>;

fn accept_optional_pointer(maybe: ?*mut u8) -> u32 {
    if let p = maybe {
        return 1;
    }
    return 0;
}

fn accept_optional_pointer_binding_type(maybe: ?*mut u8, fallback: *mut u8) -> *mut u8 {
    if let p = maybe {
        return p;
    }
    return fallback;
}

fn accept_direct_call_optional_pointer_binding_type(fallback: *mut u8) -> *mut u8 {
    if let p = make_nullable_pointer() {
        return p;
    }
    return fallback;
}

fn reject_optional_pointer_binding_return_type(maybe: ?*mut u8) -> u32 {
    if let p = maybe {
        // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
        return p;
    }
    return 0;
}

fn reject_direct_call_optional_pointer_binding_return_type() -> u32 {
    if let p = make_nullable_pointer() {
        // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
        return p;
    }
    return 0;
}

fn accept_result_ok(result: Result<u32, Error>) -> u32 {
    if let ok(v) = result {
        return 1;
    }
    return 0;
}

fn reject_result_ok_binding_return_type(result: Result<u32, Error>, fallback: *mut u8) -> *mut u8 {
    if let ok(v) = result {
        // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
        return v;
    }
    return fallback;
}

fn accept_direct_call_result_ok_binding_type() -> u32 {
    if let ok(v) = make_result_u32() {
        return v;
    }
    return 0;
}

fn accept_grouped_direct_call_result_ok_binding_type() -> u32 {
    if let ok(v) = (make_result_u32()) {
        return v;
    }
    return 0;
}

fn reject_direct_call_result_ok_binding_return_type(fallback: *mut u8) -> *mut u8 {
    if let ok(v) = make_result_u32() {
        // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
        return v;
    }
    return fallback;
}

fn accept_result_err(result: Result<u32, Error>) -> u32 {
    if let err(e) = result {
        return 1;
    }
    return 0;
}

fn reject_result_err_binding_return_type(result: Result<u32, *mut u8>) -> u32 {
    if let err(e) = result {
        // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
        return e;
    }
    return 0;
}

fn reject_direct_call_result_err_binding_return_type() -> u32 {
    if let err(e) = make_result_err_pointer() {
        // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
        return e;
    }
    return 0;
}

fn accept_switch_result_ok_binding_type(result: Result<u32, Error>) -> u32 {
    switch result {
        ok(v) => { return v; },
        _ => { return 0; },
    }
}

fn reject_switch_result_ok_binding_return_type(result: Result<u32, Error>, fallback: *mut u8) -> *mut u8 {
    switch result {
        ok(v) => {
            // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
            return v;
        },
        _ => { return fallback; },
    }
}

fn reject_switch_result_err_binding_return_type(result: Result<u32, *mut u8>) -> u32 {
    switch result {
        err(e) => {
            // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
            return e;
        },
        _ => { return 0; },
    }
}

fn reject_switch_unknown_result_tag(result: Result<u32, Error>) -> u32 {
    switch result {
        // EXPECT_ERROR: E_SWITCH_RESULT_TAG
        ready(v) => { return 1; },
        _ => { return 0; },
    }
}

fn reject_switch_result_binding_from_non_result(maybe: ?*mut u8) -> u32 {
    switch maybe {
        // EXPECT_ERROR: E_SWITCH_RESULT_REQUIRED
        ok(v) => { return 1; },
        _ => { return 0; },
    }
}

fn reject_switch_multi_pattern_binding(result: Result<u32, Error>) -> u32 {
    switch result {
        // EXPECT_ERROR: E_SWITCH_MULTI_BINDING_ARM
        ok(v), err(e) => { return 1; },
        _ => { return 0; },
    }
}

fn reject_plain_binding_from_non_nullable(n: u32) -> u32 {
    // EXPECT_ERROR: E_IF_LET_OPTIONAL_REQUIRED
    if let x = n {
        return 1;
    }
    return 0;
}

fn reject_result_binding_from_non_result(maybe: ?*mut u8) -> u32 {
    // EXPECT_ERROR: E_IF_LET_RESULT_REQUIRED
    if let ok(v) = maybe {
        return 1;
    }
    return 0;
}

fn reject_unknown_result_tag(result: Result<u32, Error>) -> u32 {
    // EXPECT_ERROR: E_IF_LET_RESULT_TAG
    if let ready(v) = result {
        return 1;
    }
    return 0;
}

fn reject_general_if_pattern(status: Status) -> u32 {
    // EXPECT_ERROR: E_IF_LET_NARROW_PATTERN
    if let .ready = status {
        return 1;
    }
    return 0;
}
