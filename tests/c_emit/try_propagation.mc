global shared_value: u32 = 0;

extern fn make_result_u32() -> Result<u32, Error>;
extern fn make_nullable_pointer() -> ?*const u8;
extern fn next_value() -> u32;
extern fn combine_u32(left: u32, right: u32) -> u32;
extern fn consume_pair(left: u32, right: u32) -> void;
extern fn consume_u32(value: u32) -> void;
extern fn consume_ptr(ptr: *const u8) -> u32;
extern fn choose_ptr(left: *const u8, right: *const u8) -> *const u8;

fn accept_handled_result_local() -> u32 {
    let result = make_result_u32();
    return result?;
}

fn accept_assignment_handled_later() -> u32 {
    var result: Result<u32, Error> = make_result_u32();
    result?;
    result = make_result_u32();
    return result?;
}

fn accept_result_switch_handles_both_tags() -> void {
    let result = make_result_u32();
    switch result {
        ok(value) => {
            consume_u32(value);
        },
        err(e) => {
            consume_u32(0);
        },
    }
}

fn accept_result_handled_in_unsafe_block() -> void {
    let result = make_result_u32();
    unsafe {
        switch result {
            ok(value) => {
                consume_u32(value);
            },
            err(e) => {
                consume_u32(0);
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
                consume_u32(value);
            },
            err(e) => {
                consume_u32(0);
            },
        }
    }
}

fn assign_result_try() -> Result<u32, Error> {
    var value: u32 = make_result_u32()?;
    value = make_result_u32()?;
    shared_value = make_result_u32()?;
    return ok(value);
}

fn expr_result_try() -> Result<u32, Error> {
    make_result_u32()?;
    consume_u32(make_result_u32()?);
    return ok(1);
}

fn assign_nullable_try() -> *const u8 {
    var ptr: *const u8 = make_nullable_pointer()?;
    ptr = make_nullable_pointer()?;
    return ptr;
}

fn nullable_try_call_arg(maybe: ?*const u8) -> u32 {
    return consume_ptr(maybe?);
}

fn nullable_try_two_args(maybe: ?*const u8) -> *const u8 {
    return choose_ptr(maybe?, make_nullable_pointer()?);
}

fn result_try_rhs_after_call() -> Result<u32, Error> {
    let value: u32 = next_value() + make_result_u32()?;
    return ok(value);
}

fn result_try_assignment_rhs_after_call() -> Result<u32, Error> {
    var value: u32 = 0;
    value = next_value() + make_result_u32()?;
    return ok(value);
}

fn result_try_return_rhs_after_call() -> u32 {
    return next_value() + make_result_u32()?;
}

fn result_try_call_rhs_after_call() -> u32 {
    return combine_u32(next_value(), make_result_u32()?);
}

fn result_try_call_local_rhs_after_call() -> Result<u32, Error> {
    let value: u32 = combine_u32(next_value(), make_result_u32()?);
    return ok(value);
}

fn result_try_call_assignment_rhs_after_call() -> Result<u32, Error> {
    var value: u32 = 0;
    value = combine_u32(next_value(), make_result_u32()?);
    return ok(value);
}

fn result_try_call_expr_rhs_after_call() -> Result<u32, Error> {
    consume_pair(next_value(), make_result_u32()?);
    return ok(0);
}

fn nullable_try_call_two_unwraps() -> *const u8 {
    return choose_ptr(make_nullable_pointer()?, make_nullable_pointer()?);
}
