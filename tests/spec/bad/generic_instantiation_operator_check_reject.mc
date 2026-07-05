// SPEC: section=5,22
// SPEC: milestone=generic-instantiation-operator-check
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_OPERATOR_OPERAND

// A generic template can mention an operator on placeholder T during template
// precheck, but each concrete instantiation must be checked against the
// substituted body before backend emission.

struct S {
    x: u32,
}

fn add_one(comptime T: type, x: T) -> T {
    return x + 1; // EXPECT_ERROR: E_OPERATOR_OPERAND
}

fn same(comptime T: type, a: T, b: T) -> bool {
    return a == b; // EXPECT_ERROR: E_OPERATOR_OPERAND
}

export fn reject_struct_instantiation() -> u32 {
    let s: S = .{ .x = 1 };
    let y: S = add_one(S, s);
    if same(S, s, y) {
        return 0;
    }
    return y.x;
}
