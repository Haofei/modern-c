// SPEC: section=21.1
// SPEC: milestone=diagnostic-fixtures
// SPEC: phase=parse,sema
// SPEC: expect=compile_error
// SPEC: check=E_CONST_GET_BASE,E_CONST_GET_BOUNDS,E_CONST_GET_INDEX

fn reject_const_get_base(xs: []const u32) -> u32 {
    return xs.const_get<0>(); // EXPECT_ERROR: E_CONST_GET_BASE
}

fn reject_const_get_bounds(xs: [2]u32) -> u32 {
    return xs.const_get<2>(); // EXPECT_ERROR: E_CONST_GET_BOUNDS
}

fn reject_const_get_index(xs: [2]u32) -> u32 {
    return xs.const_get(); // EXPECT_ERROR: E_CONST_GET_INDEX
}
