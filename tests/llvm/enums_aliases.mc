type Count = u32;
type Counts = [3]Count;
type RawBytes = [*]mut u8;

enum OpenError {
    not_found,
    denied,
    bad_path,
}

enum Irq: u8 {
    timer = 32,
    keyboard = 33,
}

enum SignedIrq: i8 {
    negative = -1,
    zero = 0,
    positive = 1,
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

struct ErrorBox {
    error: OpenError,
}

global default_error: OpenError = .denied;
global default_errors: [2]OpenError = .{ .not_found, .bad_path };
global counts: Counts = .{ 1, 2, 3 };

extern fn consume_error(error: OpenError) -> void;

fn alias_param_return(value: Count) -> Count {
    let local: Count = value;
    return local;
}

fn alias_checked_arithmetic(a: Count, b: Count) -> Count {
    return a + b;
}

fn alias_array_index(i: usize) -> Count {
    return counts[i];
}

fn alias_raw_offset(p: RawBytes, i: usize) -> RawBytes {
    unsafe {
        return p.offset(i);
    }
}

fn enum_local_initializer() -> OpenError {
    let error: OpenError = .not_found;
    return error;
}

fn enum_return() -> OpenError {
    return .bad_path;
}

fn enum_call_arg() -> void {
    consume_error(.denied);
}

fn enum_assignment() -> OpenError {
    var error: OpenError = .not_found;
    error = .denied;
    return error;
}

fn enum_array_literal() -> OpenError {
    let errors: [2]OpenError = .{ .not_found, .bad_path };
    return errors[1];
}

fn enum_global_read() -> OpenError {
    return default_error;
}

fn enum_global_array_read() -> OpenError {
    return default_errors[1];
}

fn enum_field_read(box: ErrorBox) -> OpenError {
    return box.error;
}

fn open_enum_integer_cast(value: u8) -> DeviceState {
    return value as DeviceState;
}

fn open_enum_raw(state: DeviceState) -> u8 {
    return state.raw();
}

fn signed_enum_value() -> SignedIrq {
    return .negative;
}

fn ascii_code() -> AsciiCode {
    return .letter_a;
}

fn classify_irq(irq: Irq) -> u32 {
    switch irq {
        .timer => {
            return 1;
        },
        .keyboard => {
            return 2;
        },
    }
}

fn classify_error(error: OpenError) -> u32 {
    switch error {
        .not_found => {
            return 0;
        },
        .denied => {
            return 1;
        },
        .bad_path => {
            return 2;
        },
    }
}

fn classify_error_wildcard(error: OpenError) -> u32 {
    switch error {
        .denied => {
            return 1;
        },
        _ => {
            return 0;
        },
    }
}
