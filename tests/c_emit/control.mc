fn count_down(n: u32) -> u32 {
    var x: u32 = n;
    while x != 0 {
        x = x - 1;
    }
    return x;
}

fn bool_switch(flag: bool) -> u32 {
    switch flag {
        true => { return 1; },
        false => { return 0; },
    }
}

fn bool_switch_wildcard(flag: bool) -> u32 {
    switch flag {
        true => { return 1; },
        _ => { return 0; },
    }
}

fn int_switch(n: u32) -> u32 {
    switch n {
        0 => { return 10; },
        1, 2 => { return 20; },
        _ => { return 30; },
    }
}
