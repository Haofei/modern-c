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

fn wrap_and(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
    return a & b;
}

fn wrap_or(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
    return a | b;
}

fn wrap_xor(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
    return a ^ b;
}

fn wrap_not(a: wrap<u32>) -> wrap<u32> {
    return ~a;
}

fn wrap_left_shift(a: wrap<u32>, n: wrap<u32>) -> wrap<u32> {
    return a << n;
}

fn wrap_right_shift(a: wrap<u32>, n: wrap<u32>) -> wrap<u32> {
    return a >> n;
}

extern fn next_bits() -> u32;
extern fn consume_bits(value: u32) -> void;

fn ordered_bitwise_return() -> u32 {
    return next_bits() & next_bits();
}

fn ordered_bitwise_local() -> u32 {
    let value: u32 = next_bits() | next_bits();
    return value;
}

fn ordered_bitwise_inferred_local() -> u32 {
    let value = next_bits() ^ next_bits();
    return value;
}

fn ordered_bitwise_assignment() -> u32 {
    var value: u32 = 0;
    value = next_bits() & next_bits();
    return value;
}

fn ordered_bitwise_arg() -> void {
    consume_bits(next_bits() | next_bits());
}
