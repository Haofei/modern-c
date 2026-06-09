// Value-range proof: checked arithmetic on constant operands that provably
// cannot overflow lowers to plain C arithmetic (no overflow helper).
fn safe_add() -> u8 {
    let z: u8 = 200 + 50;
    return z;
}

fn safe_mul() -> u16 {
    let z: u16 = 100 * 100;
    return z;
}

fn safe_sub() -> u8 {
    let z: u8 = 50 - 10;
    return z;
}

// Runtime operands stay checked.
fn runtime_add(a: u8, b: u8) -> u8 {
    return a + b;
}

// Operands that may overflow stay checked.
fn maybe_overflow() -> u8 {
    let z: u8 = 200 + 100;
    return z;
}

// Variable-range propagation: a constant flows through an immutable `let` local
// to prove a downstream checked op trap-free.
fn const_local_chain() -> u8 {
    let base: u8 = 200;
    let z: u8 = base + 50;
    return z;
}

fn const_local_mul() -> u16 {
    let n: u16 = 100;
    let z: u16 = n * 50;
    return z;
}
