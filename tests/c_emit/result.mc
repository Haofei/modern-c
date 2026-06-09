fn make_ok(value: u32) -> Result<u32, Error> {
    return ok(value);
}

extern fn make_result() -> Result<u32, Error>;
extern fn make_result_from(seed: u32) -> Result<u32, Error>;
extern fn next_seed() -> u32;

fn unwrap_ok(result: Result<u32, Error>) -> u32 {
    return result?;
}

fn unwrap_call_result() -> u32 {
    return make_result()?;
}

fn unwrap_or_zero(result: Result<u32, Error>) -> u32 {
    if let ok(value) = result {
        return value;
    } else {
        return 0;
    }
}

fn unwrap_call_seed_or_zero() -> u32 {
    if let ok(value) = make_result_from(next_seed()) {
        return value;
    } else {
        return 0;
    }
}

fn is_error(result: Result<u32, Error>) -> bool {
    if let err(e) = result {
        return true;
    } else {
        return false;
    }
}

fn result_switch_value(result: Result<u32, Error>) -> u32 {
    switch result {
        ok(value) => {
            return value;
        },
        err(e) => {
            return 0;
        },
    }
}

fn result_switch_call_seed() -> u32 {
    switch make_result_from(next_seed()) {
        ok(value) => {
            return value;
        },
        err(e) => {
            return 0;
        },
    }
}

fn result_payloadless_switch() -> u32 {
    let result = make_ok(1);
    switch result {
        .ok => {
            return 1;
        },
        .err => {
            return 0;
        },
    }
}
