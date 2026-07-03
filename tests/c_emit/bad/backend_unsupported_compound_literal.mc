// EXPECT: E_BACKEND_UNSUPPORTED

export fn main() -> u32 {
    .{ 1, 2 };
    return 0;
}
