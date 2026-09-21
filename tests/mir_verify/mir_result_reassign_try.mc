extern fn make_result_u32() -> Result<u32, Error>;
extern fn make_void() -> void;

fn reject_overwrite_unhandled_result() -> u32 {
    var result = make_result_u32();
    result = make_result_u32();
    return result?;
}

fn accept_assignment_handled_later() -> u32 {
    var result: Result<u32, Error> = make_result_u32();
    result?;
    result = make_result_u32();
    return result?;
}

fn reject_void_direct_call_try() -> void {
    return make_void()?;
}

fn reject_integer_try(n: u32) -> u32 {
    return n?;
}
