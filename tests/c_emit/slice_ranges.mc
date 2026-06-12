fn slice_first(buf: []mut u8, n: usize) -> u8 {
    let s: []mut u8 = buf[0..n];
    return s[0];
}

fn slice_array(n: usize) -> u8 {
    var buf: [4]u8 = uninit;
    buf[0] = 9;
    let s: []mut u8 = buf[0..n];
    return s[0];
}

fn slice_return(buf: []mut u8, lo: usize, hi: usize) -> []mut u8 {
    return buf[lo..hi];
}
