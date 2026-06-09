type W = wrap<u32>;

fn widen(a: u32) -> u64 {
    return u64.from(a);
}

fn narrow_wrap(x: u32) -> u8 {
    return u8.wrap_from(x);
}

fn narrow_trap(x: u32) -> u8 {
    return u8.trap_from(x);
}

fn narrow_sat(x: u32) -> u8 {
    return u8.sat_from(x);
}

fn widen_trap(x: u8) -> u64 {
    return u64.trap_from(x);
}

fn make_wrap(a: u32) -> W {
    return W.from(a);
}

fn make_wrap_mod() -> W {
    return W.from_mod(300);
}

fn raw(word: W) -> u32 {
    return word.residue();
}
