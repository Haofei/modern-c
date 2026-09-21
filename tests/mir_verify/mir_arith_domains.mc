type HashWord = wrap<u32>;
type Level = sat<u8>;
type Seq = serial<u32>;
type Ticks = counter<u64>;

fn reject_wrap_checked_mix(a: HashWord, b: u32) -> HashWord {
    return a + b;
}

fn reject_sat_bitwise(a: Level, b: Level) -> Level {
    return a & b;
}

fn reject_wrap_div(a: HashWord, b: HashWord) -> HashWord {
    return a / b;
}

fn reject_serial_checked_mix(a: Seq, b: u32) -> Seq {
    return a + b;
}

fn reject_counter_bitwise(a: Ticks, b: Ticks) -> Ticks {
    return a & b;
}

fn reject_cast_wrap_checked_mix(a: u32, b: u32) -> HashWord {
    return (a as HashWord) + b;
}

fn reject_cast_sat_bitwise(a: u8, b: u8) -> Level {
    return (a as Level) & (b as Level);
}
