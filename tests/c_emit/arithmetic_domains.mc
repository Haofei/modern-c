fn wrap_add(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
    return a + b;
}

fn wrap_sub(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
    return a - b;
}

fn wrap_mul(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
    return a * b;
}

fn wrap_and(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
    return a & b;
}

fn wrap_shift(a: wrap<u32>, n: wrap<u32>) -> wrap<u32> {
    return a << n;
}

fn sat_add(a: sat<u32>, b: sat<u32>) -> sat<u32> {
    return a + b;
}

fn sat_sub(a: sat<u32>, b: sat<u32>) -> sat<u32> {
    return a - b;
}

fn sat_mul(a: sat<u16>, b: sat<u16>) -> sat<u16> {
    return a * b;
}

fn sat_order(a: sat<u32>, b: sat<u32>) -> bool {
    return a >= b;
}

fn sat_literal() -> sat<u8> {
    let level: sat<u8> = 250;
    return level;
}

fn inferred_wrap_add(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
    let x = a + b;
    return x;
}

fn inferred_sat_mul(a: sat<u16>, b: sat<u16>) -> sat<u16> {
    let x = a * b;
    return x;
}
