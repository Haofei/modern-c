// Full-selfhost P0 positive fixture: tiny hosted emit-C/run and LLVM object smoke.

export fn full_selfhost_add(a: u32, b: u32) -> u32 {
    return a + b;
}

export fn full_selfhost_run() -> u32 {
    return full_selfhost_add(20, 22);
}
