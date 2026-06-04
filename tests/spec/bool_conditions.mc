// SPEC: section=25,D.1
// SPEC: milestone=bool-conditions
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_CONDITION_NOT_BOOL,E_BOOL_OPERATOR_OPERAND

fn accept_bool_while(flag: bool) -> u32 {
    while flag {
        return 1;
    }
    return 0;
}

fn accept_explicit_integer_comparison(n: u32) -> bool {
    return n != 0;
}

fn accept_bool_operators(a: bool, b: bool) -> bool {
    return !a || (a && b);
}

fn accept_assert_bool(flag: bool) -> void {
    assert(flag);
}

fn reject_integer_while(n: u32) -> u32 {
    // EXPECT_ERROR: E_CONDITION_NOT_BOOL
    while n {
        return 1;
    }
    return 0;
}

fn reject_pointer_assert(p: *const u8) -> void {
    // EXPECT_ERROR: E_CONDITION_NOT_BOOL
    assert(p);
}

fn reject_integer_not(n: u32) -> bool {
    // EXPECT_ERROR: E_BOOL_OPERATOR_OPERAND
    return !n;
}

fn reject_integer_logical_and(flag: bool, n: u32) -> bool {
    // EXPECT_ERROR: E_BOOL_OPERATOR_OPERAND
    return flag && n;
}

fn reject_integer_logical_or(flag: bool, n: u32) -> bool {
    // EXPECT_ERROR: E_BOOL_OPERATOR_OPERAND
    return n || flag;
}
