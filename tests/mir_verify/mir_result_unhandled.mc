extern fn make_result_u32() -> Result<u32, Error>;

fn reject_unhandled_result_statement() -> void {
    make_result_u32();
}

fn reject_unhandled_result_local() -> void {
    let result = make_result_u32();
}

fn reject_defer_unhandled_result() -> void {
    defer make_result_u32();
}

fn reject_switch_arm_unhandled_result(flag: bool) -> void {
    switch flag {
        true => make_result_u32(),
        false => {},
    }
}
