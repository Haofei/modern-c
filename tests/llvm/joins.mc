fn adjust(n: u32, flag: bool) -> u32 {
    var x: u32 = n;
    if flag {
        x = x + 1;
    } else {
        x = x - 1;
    }
    return x;
}

fn maybe_inc(n: u32, flag: bool) -> u32 {
    var x: u32 = n;
    if flag {
        x = x + 1;
    }
    return x;
}
