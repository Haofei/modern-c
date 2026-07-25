export fn typed_integer_literals() -> u32 {
    if 0x20_u8 != 32_u8 {
        return 1;
    }
    let a: u16 = 1_u16;
    let b: u32 = 2_u32;
    let c: u64 = 3_u64;
    let d: u128 = 4_u128;
    let e: usize = 5_usize;
    let f: i8 = 6_i8;
    let g: i16 = 7_i16;
    let h: i32 = 8_i32;
    let i: i64 = 9_i64;
    let j: i128 = 10_i128;
    let k: isize = 11_isize;
    if a != 1_u16 || b != 2_u32 || c != 3_u64 || d != 4_u128 ||
        e != 5_usize || f != 6_i8 || g != 7_i16 || h != 8_i32 ||
        i != 9_i64 || j != 10_i128 || k != 11_isize {
        return 2;
    }
    return 0;
}

export fn long_typed_integer_literal() -> u8 {
    return 000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001_u8;
}
