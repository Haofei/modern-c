// EXPECT: E_BACKEND_UNSUPPORTED

export fn main() -> u32 {
    let ok: u32 = 1;
    unsafe {
        asm opaque volatile {
            "nop"
            in("r") ok: u32
        }
    }
    return ok;
}
