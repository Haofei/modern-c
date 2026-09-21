struct ResultBox {
    value: u32,
}

extern fn make_result_u32() -> Result<u32, Error>;

fn accept_handled_result_local() -> u32 {
    let result = make_result_u32();
    return result?;
}

fn accept_if_let_else_result() -> void {
    let result = make_result_u32();
    if let ok(value) = result {
        let copy: u32 = value;
    } else {
        let fallback: u32 = 0;
    }
}

fn accept_result_switch_handles_both_tags() -> void {
    let result = make_result_u32();
    switch result {
        ok(value) => {
            let copy: u32 = value;
        },
        err(e) => {
            let fallback: u32 = 0;
        },
    }
}

fn accept_array_literal_result_local() -> void {
    let result = make_result_u32();
    let values: [1]u32 = .{ result? };
}

fn accept_struct_literal_result_local() -> void {
    let result = make_result_u32();
    let boxed: ResultBox = .{ .value = result? };
}

fn accept_switch_arm_body_result_local(flag: bool) -> u32 {
    let result = make_result_u32();
    switch flag {
        true => {
            return result?;
        },
        false => {
            return 0;
        },
    }
}
