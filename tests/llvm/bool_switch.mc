fn choose(flag: bool) -> u32 {
    switch flag {
        true => { return 11; },
        false => { return 22; },
    }
}

fn choose_default(flag: bool) -> u32 {
    switch flag {
        true => { return 33; },
        _ => { return 44; },
    }
}

fn classify(x: u32, flag: bool) -> u32 {
    if !flag {
        return 5;
    } else if x > 10 {
        return 6;
    } else {
        return 7;
    }
}
