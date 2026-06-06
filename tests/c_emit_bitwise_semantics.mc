fn unsigned_and(a: u32, b: u32) -> u32 {
    return a & b;
}

fn unsigned_or(a: u32, b: u32) -> u32 {
    return a | b;
}

fn unsigned_xor(a: u32, b: u32) -> u32 {
    return a ^ b;
}

fn unsigned_not(a: u32) -> u32 {
    return ~a;
}

fn unsigned_shift(a: u32, n: u32) -> u32 {
    return a << n;
}

fn wrap_and(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
    return a & b;
}
