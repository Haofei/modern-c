enum Irq {
    timer,
    keyboard,
}

fn reject_bool_switch_integer_pattern(flag: bool) -> void {
    switch flag {
        1 => {},
        _ => {},
    }
}

fn reject_integer_switch_bool_pattern(value: u32) -> void {
    switch value {
        true => {},
        _ => {},
    }
}

fn reject_enum_switch_literal_pattern(irq: Irq) -> void {
    switch irq {
        1 => {},
        _ => {},
    }
}

fn accept_scalar_switch_literals(flag: bool, value: u32) -> void {
    switch flag {
        true => {},
        false => {},
    }
    switch value {
        1 => {},
        2 => {},
        _ => {},
    }
}
