fn context_typed_integer_literal() -> u32 {
    let x: u32 = 10;
    return x;
}

fn u8_max_literal() -> u8 {
    let x: u8 = 255;
    return x;
}

fn i8_max_literal() -> i8 {
    let x: i8 = 127;
    return x;
}

fn i8_min_literal() -> i8 {
    let x: i8 = -128;
    return x;
}

fn grouped_i8_min_literal() -> i8 {
    let x: i8 = (-128);
    return x;
}

fn negative_hex_i8_min_literal() -> i8 {
    let x: i8 = -0x80;
    return x;
}

fn hex_u8_max_literal() -> u8 {
    let x: u8 = 0xff;
    return x;
}

fn same_width_local_initializer(a: u32) -> u32 {
    let x: u32 = a;
    return x;
}

fn same_type_arithmetic(a: u32, b: u32) -> u32 {
    return a + b;
}

fn context_typed_literal_arithmetic(a: u32) -> u32 {
    return a + 1;
}

fn same_type_comparison(a: i32, b: i32) -> bool {
    return a < b;
}
