// test: emit-llvm
// target: riscv64
// expect: pass

struct Pair {
    first: u32,
    second: u64,
}

fn read_second(pair: *Pair) -> u64 {
    return pair.second;
}

fn write_first(pair: *mut Pair, value: u32) -> void {
    pair.first = value;
}
