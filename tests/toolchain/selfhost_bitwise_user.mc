// selfhost-bitwise-test fixture: exercises mcc2's infix bitwise (`& | ^`) and shift (`<< >>`)
// operators with C-like precedence, plus the `unreachable;` diverging terminator statement, and
// proves the PREFIX address-of `&x` still parses as address-of (not infix bitwise-and) alongside an
// INFIX `&`. Each exported fn is called from the test's C driver, which asserts known values.

// bitwise-and combined with subtraction: `a & (b - 1)` (an alignment-mask idiom). `&` here is INFIX.
export fn band(a: u32, b: u32) -> u32 {
    return a & (b - 1);
}

// shift-then-or: `x << 2 | 1`. Precedence: shift (tighter) binds before `|` -> `(x << 2) | 1`.
export fn shl_or(x: u32) -> u32 {
    return x << 2 | 1;
}

// shift-then-and: `x >> 2 & 3`. `>>` (tighter) before `&` -> `(x >> 2) & 3`.
export fn shr_and(x: u32) -> u32 {
    return x >> 2 & 3;
}

// The full precedence tower in one expression: `a & b | a ^ b << 1`. C ordering (tight -> loose):
// `<<` , `&` , `^` , `|`  =>  `(a & b) | (a ^ (b << 1))`.
export fn tower(a: u32, b: u32) -> u32 {
    return a & b | a ^ b << 1;
}

// PREFIX `&x` (address-of) must still parse as address-of, NOT infix bitwise-and: take a pointer,
// deref it, then use INFIX `&` on the loaded value. Proves the prefix/infix `&` disambiguation.
export fn addr_and(x: u32) -> u32 {
    let p: *u32 = &x;
    return p.* & 3;
}

// `unreachable;` in a dead branch: the `if` always returns for the driver's inputs, so the
// terminator is never hit at runtime; it must PARSE, type-check, and emit `mc_trap_Unreachable();`
// without a trailing return (the trap is NORETURN).
export fn clamp_small(x: u32) -> u32 {
    if x < 100 {
        return x | 1;
    }
    unreachable;
}
