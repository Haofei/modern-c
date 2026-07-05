// EXPECT: E_BACKEND_UNSUPPORTED

export fn main() -> u32 {
    let ok: u32 = 1;
    .{ 1, 2 };
    return ok;
}
