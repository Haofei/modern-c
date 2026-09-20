extern fn takes_u8(value: u8) -> void;
fn integer_literals() -> u8 {
    let a: u8 = 255;
    takes_u8(0xff);
    return 7;
}
