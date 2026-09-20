fn callee(x: u32) -> u32 {
    return x;
}

fn caller() -> u32 {
    return callee(7);
}
