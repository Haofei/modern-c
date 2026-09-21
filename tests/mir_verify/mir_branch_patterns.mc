extern fn make_result_u32() -> Result<u32, Error>;

enum Status {
    ready,
    waiting,
}

fn reject_if_let_optional_required(value: u32) -> void {
    if let x = value {
    }
}

fn reject_if_let_result_required(maybe: ?*mut u8) -> void {
    if let ok(value) = maybe {
    }
}

fn reject_if_let_result_tag(result: Result<u32, Error>) -> void {
    if let ready(value) = result {
    }
}

fn reject_if_let_narrow_pattern(status: Status) -> void {
    if let .ready = status {
    }
}

fn reject_switch_result_tag(result: Result<u32, Error>) -> void {
    switch result {
        ready(value) => {},
        _ => {},
    }
}

fn reject_switch_result_required(value: u32) -> void {
    switch value {
        .ok => {},
        _ => {},
    }
}

fn reject_switch_multi_binding_arm(result: Result<u32, Error>) -> void {
    switch result {
        ok(value), err(error_value) => {},
        _ => {},
    }
}

fn accept_valid_result_patterns() -> void {
    let result = make_result_u32();
    if let ok(value) = result {
    }
    switch result {
        ok(value) => {},
        err(error_value) => {},
    }
}
