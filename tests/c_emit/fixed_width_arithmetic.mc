fn add_i8(a: i8, b: i8) -> i8 {
    return a + b;
}

fn sub_u16(a: u16, b: u16) -> u16 {
    return a - b;
}

fn mul_u64(a: u64, b: u64) -> u64 {
    return a * b;
}

fn div_i32(a: i32, b: i32) -> i32 {
    return a / b;
}

fn mod_i64(a: i64, b: i64) -> i64 {
    return a % b;
}

fn neg_i32(a: i32) -> i32 {
    return -a;
}

fn neg_isize(a: isize) -> isize {
    return -a;
}

fn shift_usize(a: usize, b: usize) -> usize {
    return (a << b) >> b;
}

fn inferred_i32_add(a: i32, b: i32) -> i32 {
    let x = a + b;
    return x;
}

fn inferred_u64_mul(a: u64, b: u64) -> u64 {
    let x = a * b;
    return x;
}

fn inferred_i32_neg(a: i32) -> i32 {
    let x = -a;
    return x;
}
