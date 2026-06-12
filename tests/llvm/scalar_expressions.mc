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

fn checked_left_shift(a: u32, n: u32) -> u32 {
    return a << n;
}

fn checked_right_shift(a: u32, n: u32) -> u32 {
    return a >> n;
}

fn nibble(v: u64, shift: u32) -> u8 {
    return ((v >> shift) & 0xF) as u8;
}

fn high_word(v: u64) -> u32 {
    let hi: u32 = (v >> 32) as u32;
    return hi + 1;
}

fn read_word(addr: usize) -> u64 {
    return (addr as u64) & 0xFF;
}

fn flag_set(addr: usize, mask: u64) -> bool {
    return (read_word(addr) & mask) != 0;
}
