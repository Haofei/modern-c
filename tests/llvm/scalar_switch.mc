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

fn classify_char(c: u8) -> u32 {
    switch c {
        'A' => { return 1; },
        '\n' => { return 2; },
        _ => { return 0; },
    }
}

fn classify_signed(n: i32) -> u32 {
    switch n {
        -1 => { return 1; },
        0 => { return 2; },
        _ => { return 0; },
    }
}
