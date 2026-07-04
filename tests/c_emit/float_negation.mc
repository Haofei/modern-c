// Regression: unary '-' on float literals and float values must lower to C.
// Before the fix, `-0.3` (a `comptime_float` literal operand) was rejected by the MIR
// verifier with E_OPERATOR_OPERAND; negation of f32/f64 values and literals is well-defined.

fn neg_literal() -> f32 {
    return -4.0;
}

fn neg_in_add(a: f32) -> f32 {
    return a + -0.3;
}

fn neg_value(a: f32) -> f32 {
    return -a;
}

fn neg_f64(a: f64) -> f64 {
    let bias: f64 = -1.5;
    return -a + bias;
}

fn weights() -> f32 {
    var w: [4]f32 = .{ 0.5, -0.3, -0.4, 0.6 };
    return (w[0] + w[1]) + (w[2] + w[3]);
}
