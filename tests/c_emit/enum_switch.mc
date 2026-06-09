enum Irq: u8 {
    timer = 32,
    keyboard = 33,
}

open enum DeviceState: u8 {
    idle = 0,
    busy = 1,
    error = 2,
}

enum ErrorKind {
    not_found,
    denied,
}

global default_irq_value: Irq = .keyboard;
global default_error_value: ErrorKind = .denied;

extern fn read_irq() -> Irq;
extern fn read_irq_from(seed: u32) -> Irq;
extern fn next_seed() -> u32;
extern fn read_state() -> DeviceState;
extern fn consume_irq(irq: Irq) -> void;
extern fn consume_pair(left: u32, right: u32) -> void;

fn default_irq() -> Irq {
    return .timer;
}

fn read_default_irq() -> Irq {
    return default_irq_value;
}

fn write_default_irq(next: Irq) -> void {
    default_irq_value = next;
}

fn read_default_error() -> ErrorKind {
    return default_error_value;
}

fn write_default_error(next: ErrorKind) -> void {
    default_error_value = next;
}

fn enum_local_initializer() -> Irq {
    let irq: Irq = .keyboard;
    return irq;
}

fn enum_assignment() -> Irq {
    var irq: Irq = .timer;
    irq = .keyboard;
    return irq;
}

fn enum_call_arg() -> void {
    consume_irq(.timer);
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

fn classify_read_irq() -> u32 {
    switch read_irq() {
        .timer => {
            return 1;
        },
        .keyboard => {
            return 2;
        },
    }
}

fn classify_read_irq_from_seed() -> u32 {
    switch read_irq_from(next_seed()) {
        .timer => {
            return 1;
        },
        .keyboard => {
            return 2;
        },
    }
}

fn switch_expr_body_order(irq: Irq) -> void {
    switch irq {
        .timer => consume_pair(next_seed(), next_seed()),
        .keyboard => consume_pair(next_seed(), next_seed()),
    }
}

fn state_raw(state: DeviceState) -> u8 {
    return state.raw();
}

fn read_state_raw() -> u8 {
    return read_state().raw();
}

fn cast_state_raw(value: u8) -> u8 {
    return (value as DeviceState).raw();
}
