fn typedef(int: u32, char: u32) -> u32 {
    let register: u32 = int + char;
    return register;
}

fn caller(long: u32) -> u32 {
    return typedef(long, long);
}
