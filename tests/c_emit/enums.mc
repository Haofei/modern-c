enum OpenError {
    not_found,
    denied,
    bad_path,
}

enum Irq: u8 {
    timer = 32,
    keyboard = 33,
}

enum AsciiCode: u8 {
    letter_a = 'A',
    newline = '\n',
}

open enum DeviceState: u8 {
    idle = 0,
    busy = 1,
    error = 2,
}

global default_error: OpenError = .denied;

extern fn takes_open_error(error: OpenError) -> void;

fn enum_local_initializer() -> OpenError {
    let error: OpenError = .not_found;
    return error;
}

fn enum_return() -> OpenError {
    return .bad_path;
}

fn enum_call_arg() -> void {
    takes_open_error(.denied);
}

fn enum_assignment() -> OpenError {
    var error: OpenError = .not_found;
    error = .denied;
    return error;
}

fn open_enum_integer_cast(value: u8) -> DeviceState {
    return value as DeviceState;
}

fn open_enum_raw(state: DeviceState) -> u8 {
    return state.raw();
}

fn closed_enum_exhaustive_switch(irq: Irq) -> void {
    switch irq {
        .timer => {},
        .keyboard => {},
    }
}

fn closed_enum_switch_wildcard(irq: Irq) -> void {
    switch irq {
        .timer => {},
        _ => {},
    }
}

fn ascii_code() -> AsciiCode {
    return .letter_a;
}
