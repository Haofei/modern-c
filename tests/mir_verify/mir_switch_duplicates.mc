fn reject_bool_duplicate(flag: bool) -> void {
    switch flag {
        true => {},
        true => {},
        false => {},
    }
}

fn reject_integer_duplicate(value: u32) -> void {
    switch value {
        1 => {},
        0x1 => {},
        _ => {},
    }
}

fn reject_result_duplicate(result: Result<u32, Error>) -> void {
    switch result {
        ok(value) => {},
        .ok => {},
        err(error_value) => {},
    }
}

fn reject_case_after_wildcard(value: u32) -> void {
    switch value {
        _ => {},
        2 => {},
    }
}

fn reject_same_arm_wildcard_cover(value: u32) -> void {
    switch value {
        _, 3 => {},
    }
}

fn accept_distinct_switches(flag: bool, value: u32, result: Result<u32, Error>) -> void {
    switch flag {
        true => {},
        false => {},
    }
    switch value {
        1 => {},
        2 => {},
        _ => {},
    }
    switch result {
        ok(value) => {},
        err(error_value) => {},
    }
}
