enum Irq {
    timer,
    keyboard,
}

open enum OpenError: u8 {
    fault = 1,
    busy = 2,
}

fn reject_closed_enum_nonexhaustive(irq: Irq) -> void {
    switch irq {
        .timer => {},
    }
}

fn reject_closed_enum_unknown_case(irq: Irq) -> void {
    switch irq {
        .missing => {},
        _ => {},
    }
}

fn reject_open_enum_unknown_case(error_value: OpenError) -> void {
    switch error_value {
        .missing => {},
        _ => {},
    }
}

fn reject_enum_duplicate_case(irq: Irq) -> void {
    switch irq {
        .timer => {},
        .timer => {},
        .keyboard => {},
    }
}

fn accept_closed_enum_exhaustive(irq: Irq) -> void {
    switch irq {
        .timer => {},
        .keyboard => {},
    }
}

fn accept_closed_enum_wildcard(irq: Irq) -> void {
    switch irq {
        .timer => {},
        _ => {},
    }
}
