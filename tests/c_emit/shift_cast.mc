// A shift's result type is its left operand's type; the amount may be a different
// width (`u64 >> u32`). Recovering that lets `(v >> shift) & mask` lower in a
// targetless / cast position (regression for the hex-nibble extraction in the
// kernel console).
fn nibble(v: u64, shift: u32) -> u8 {
    return ((v >> shift) & 0xF) as u8;
}

fn high_word(v: u64) -> u32 {
    let hi: u32 = (v >> 32) as u32;
    return hi + 1;
}

// A comparison-return whose operand involves a call lowers correctly: the bare
// literal adopts the call's width (`(u64_call & flag) != 0`), no `if`-guard
// workaround needed. (Regression for the page-table / checksum predicates.)
fn read_word(addr: usize) -> u64 {
    return (addr as u64) & 0xFF;
}
fn flag_set(addr: usize, mask: u64) -> bool {
    return (read_word(addr) & mask) != 0;
}
