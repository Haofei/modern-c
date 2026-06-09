fn classify_bool(flag: bool) -> u32 {
    switch flag {
        true => { return 1; },
        false => { return 0; },
    }
}

fn classify_bool_default(flag: bool) -> u32 {
    switch flag {
        true => { return 1; },
        _ => { return 0; },
    }
}

fn classify_integer(n: u32) -> u32 {
    switch n {
        0 => { return 10; },
        1, 2 => { return 20; },
        _ => { return 30; },
    }
}

fn switch_expr_arm(n: u32) -> u32 {
    switch n {
        0 => { return 10; },
        1 => { return 20; },
        _ => { return 30; },
    }
}
