// EXPECT: E_RAW_AGGREGATE_UNSUPPORTED

struct Pair {
    left: u32,
    right: u32,
}

fn rejected(addr: PAddr) -> Pair {
    unsafe {
        return raw.load<Pair>(addr);
    }
}
