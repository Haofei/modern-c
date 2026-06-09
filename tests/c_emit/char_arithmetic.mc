// A char literal used as a checked-arithmetic operand (`c - '0'`) must lower to
// compilable C: the char literal adopts its sibling operand's integer storage
// type, so the checked-subtraction helper is emitted with the right width.
// Previously a targetless `c - '0'` (e.g. inside a cast or switch arm) bailed.

fn digit_value(c: u8) -> u32 {
    switch c >= '0' && c <= '9' {
        true => { return (c - '0') as u32; },
        false => { return 0; },
    }
}

fn shift_letter(c: u8) -> u8 {
    return c + 1;
}

fn distance(a: u8) -> u8 {
    return a - 'A';
}
