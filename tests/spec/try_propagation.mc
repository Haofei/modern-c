// SPEC: section=10,21,D.1
// SPEC: milestone=try-propagation
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_TRY_REQUIRES_RESULT_OR_NULLABLE,E_RETURN_TYPE_MISMATCH,E_CALL_ARG_COUNT,E_UNHANDLED_RESULT

extern fn make_result_u32() -> Result<u32, Error>;
extern fn make_result_pointer(p: *mut u8) -> Result<*mut u8, Error>;
extern fn make_nullable_pointer() -> ?*const u8;
extern fn make_nullable_mut_pointer() -> ?*mut u8;
extern fn make_void() -> void;

fn accept_nullable_try(maybe: ?*const u8) -> *const u8 {
    return maybe?;
}

fn accept_result_try(result: Result<u32, Error>) -> u32 {
    return result?;
}

fn accept_result_pointer_try(result: Result<*mut u8, Error>) -> *mut u8 {
    return result?;
}

fn accept_direct_call_result_try() -> u32 {
    return make_result_u32()?;
}

fn accept_grouped_direct_call_result_try() -> u32 {
    return (make_result_u32())?;
}

fn accept_direct_call_result_pointer_try(p: *mut u8) -> *mut u8 {
    return make_result_pointer(p)?;
}

fn accept_direct_call_nullable_try() -> *const u8 {
    return make_nullable_pointer()?;
}

fn accept_direct_call_nullable_mut_pointer_try() -> *mut u8 {
    return make_nullable_mut_pointer()?;
}

fn reject_unhandled_result_statement() -> void {
    // EXPECT_ERROR: E_UNHANDLED_RESULT
    make_result_u32();
}

fn reject_unhandled_result_local() -> void {
    // EXPECT_ERROR: E_UNHANDLED_RESULT
    let result = make_result_u32();
}

fn accept_handled_result_local() -> u32 {
    let result = make_result_u32();
    return result?;
}

fn reject_overwrite_unhandled_result() -> u32 {
    var result = make_result_u32();
    // EXPECT_ERROR: E_UNHANDLED_RESULT
    result = make_result_u32();
    return result?;
}

fn reject_assignment_unhandled_result() -> void {
    var result: Result<u32, Error> = make_result_u32();
    result?;
    // EXPECT_ERROR: E_UNHANDLED_RESULT
    result = make_result_u32();
}

fn accept_assignment_handled_later() -> u32 {
    var result: Result<u32, Error> = make_result_u32();
    result?;
    result = make_result_u32();
    return result?;
}

fn reject_partial_if_let_result() -> void {
    // EXPECT_ERROR: E_UNHANDLED_RESULT
    let result = make_result_u32();
    if let ok(value) = result {
        let copy: u32 = value;
    }
}

fn accept_if_let_else_result() -> void {
    let result = make_result_u32();
    if let ok(value) = result {
        let copy: u32 = value;
    } else {
        let fallback: u32 = 0;
    }
}

fn accept_result_switch_handles_both_tags() -> void {
    let result = make_result_u32();
    switch result {
        ok(value) => {
            let copy: u32 = value;
        },
        err(e) => {
            let fallback: u32 = 0;
        },
    }
}

fn accept_result_handled_in_nested_block() -> void {
    let result = make_result_u32();
    {
        switch result {
            ok(value) => {
                let copy: u32 = value;
            },
            err(e) => {
                let fallback: u32 = 0;
            },
        }
    }
}

fn accept_result_handled_in_unsafe_block() -> void {
    let result = make_result_u32();
    unsafe {
        switch result {
            ok(value) => {
                let copy: u32 = value;
            },
            err(e) => {
                let fallback: u32 = 0;
            },
        }
    }
}

fn accept_result_handled_in_contract_block() -> void {
    let result = make_result_u32();
    #[unsafe_contract(no_overflow)]
    {
        switch result {
            ok(value) => {
                let copy: u32 = value;
            },
            err(e) => {
                let fallback: u32 = 0;
            },
        }
    }
}

fn reject_result_handled_only_in_loop() -> void {
    // EXPECT_ERROR: E_UNHANDLED_RESULT
    let result = make_result_u32();
    while false {
        switch result {
            ok(value) => {
                let copy: u32 = value;
            },
            err(e) => {
                let fallback: u32 = 0;
            },
        }
    }
}

fn reject_result_switch_partial_tags() -> void {
    // EXPECT_ERROR: E_UNHANDLED_RESULT
    let result = make_result_u32();
    switch result {
        ok(value) => {
            let copy: u32 = value;
        },
    }
}

fn reject_defer_unhandled_result() -> void {
    // EXPECT_ERROR: E_UNHANDLED_RESULT
    defer make_result_u32();
}

fn reject_result_try_return_type(result: Result<u32, Error>) -> *mut u8 {
    // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
    return result?;
}

fn reject_nullable_try_return_type(maybe: ?*const u8) -> u32 {
    // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
    return maybe?;
}

fn reject_direct_call_result_try_return_type() -> *mut u8 {
    // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
    return make_result_u32()?;
}

fn reject_direct_call_nullable_try_return_type() -> u32 {
    // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
    return make_nullable_pointer()?;
}

// The `?` try-unwrap yields a `*mut u8` ok/some payload that const-narrows to the `*const u8`
// return type — an allowed G30 coercion (identical plain-pointer repr).
fn accept_direct_call_result_pointer_try_return_conversion(p: *mut u8) -> *const u8 {
    return make_result_pointer(p)?;
}

fn accept_direct_call_nullable_pointer_try_return_conversion() -> *const u8 {
    return make_nullable_mut_pointer()?;
}

fn reject_void_direct_call_try() -> void {
    // EXPECT_ERROR: E_TRY_REQUIRES_RESULT_OR_NULLABLE
    return make_void()?;
}

fn reject_direct_call_try_preserves_arg_check() -> *mut u8 {
    // EXPECT_ERROR: E_CALL_ARG_COUNT
    return make_result_pointer()?;
}

fn reject_integer_try(n: u32) -> u32 {
    // EXPECT_ERROR: E_TRY_REQUIRES_RESULT_OR_NULLABLE
    return n?;
}

fn reject_bool_try(flag: bool) -> bool {
    // EXPECT_ERROR: E_TRY_REQUIRES_RESULT_OR_NULLABLE
    return flag?;
}

fn reject_non_null_pointer_try(p: *const u8) -> *const u8 {
    // EXPECT_ERROR: E_TRY_REQUIRES_RESULT_OR_NULLABLE
    return p?;
}
