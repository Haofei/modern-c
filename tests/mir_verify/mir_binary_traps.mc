fn unsigned_div(a: u32, b: u32) -> u32 {
    return a / b;
}

fn unsigned_rem(a: u32, b: u32) -> u32 {
    return a % b;
}

fn signed_div(a: i32, b: i32) -> i32 {
    return a / b;
}

fn signed_rem(a: i32, b: i32) -> i32 {
    return a % b;
}

fn checked_shl(a: u32, b: u32) -> u32 {
    return a << b;
}

fn checked_shr(a: u32, b: u32) -> u32 {
    return a >> b;
}

#[no_lang_trap]
fn reject_no_lang_div(a: u32, b: u32) -> u32 {
    return a / b;
}
