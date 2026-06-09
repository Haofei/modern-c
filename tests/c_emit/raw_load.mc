// raw.load<T>(addr) reads a T from a raw address (the dual of raw.store); it
// requires `unsafe` and recovers its type from the type argument.
fn read_reg(addr: usize) -> u32 {
    unsafe {
        return raw.load<u32>(phys(addr));
    }
}

fn read_byte_then_add(addr: usize) -> u32 {
    unsafe {
        let b: u8 = raw.load<u8>(phys(addr));
        return (b as u32) + 1;
    }
}

fn copy_word(src: usize, dst: usize) -> void {
    unsafe {
        let v: u32 = raw.load<u32>(phys(src));
        raw.store<u32>(phys(dst), v);
    }
}
