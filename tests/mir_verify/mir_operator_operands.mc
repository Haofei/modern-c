fn reject_unsigned_negation(x: u32) -> u32 {
    return -x;
}

fn reject_integer_not(n: u32) -> bool {
    return !n;
}

fn reject_integer_logical_and(flag: bool, n: u32) -> bool {
    return flag && n;
}

fn reject_signed_bitwise(a: i32, b: i32) -> i32 {
    return a & b;
}

fn reject_bool_bitwise(a: bool, b: bool) -> bool {
    return a & b;
}

fn reject_pointer_bitwise(a: *mut u8, b: *mut u8) -> *mut u8 {
    return a & b;
}

fn reject_null_bitwise() -> void {
    let value = null & null;
}
