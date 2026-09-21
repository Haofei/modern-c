extern fn takes_u8(value: u8) -> void;

fn accept_literals() -> u8 {
    let a: u8 = 255;
    let b: i8 = -128;
    takes_u8(0xff);
    return 255;
}

fn reject_return_literal() -> u8 {
    return 256;
}

fn reject_local_literal() -> u8 {
    let y: u8 = 0x100;
    return 0;
}

fn reject_negative_unsigned() -> u8 {
    let y: u8 = -1;
    return 0;
}

fn reject_i8_high() -> i8 {
    let y: i8 = 128;
    return 0;
}

fn reject_i8_low() -> i8 {
    let y: i8 = -129;
    return 0;
}

fn reject_assignment_literal() -> void {
    var y: u8 = 0;
    y = 300;
}

fn reject_call_arg_literal() -> void {
    takes_u8(999);
}
