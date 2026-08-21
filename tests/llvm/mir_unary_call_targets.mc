// test: emit-llvm
// target: riscv64
// expect: pass

open enum State: u8 {
    ready = 1,
}

fn float_bits(value: f32) -> u32 {
    return bitcast<u32>(value);
}

fn bits_float(value: u32) -> f32 {
    return bitcast<f32>(value);
}

fn state_raw(state: State) -> u8 {
    return state.raw();
}
