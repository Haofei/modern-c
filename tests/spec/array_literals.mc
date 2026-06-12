// SPEC: section=9
// SPEC: milestone=array-literals
// SPEC: phase=parse,sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_ARRAY_LITERAL_REQUIRES_TARGET,E_ARRAY_LITERAL_LENGTH,E_ARRAY_LENGTH_TYPE,E_RETURN_TYPE_MISMATCH

extern fn consume_array(xs: [2]u32) -> void;

struct Cell {
    value: u32,
}

global default_values: [2]u32 = .{1, 2};
global default_cells: [2]Cell = .{ .{ .value = 1 }, .{ .value = 2 } };
global default_matrix: [2][2]u32 = .{ .{ 1, 2 }, .{ 3, 4 } };

fn accept_local_array_literal() -> u32 {
    let xs: [2]u32 = .{1, 2};
    return xs[1];
}

fn accept_const_expr_length_array_literal() -> u32 {
    let xs: [1 + 2]u32 = .{1, 2, 3};
    return xs[2];
}

fn accept_return_array_literal() -> [2]u32 {
    return .{3, 4};
}

fn accept_assignment_array_literal() -> [2]u32 {
    var xs: [2]u32 = uninit;
    xs = .{5, 6};
    return xs;
}

fn accept_call_array_literal() -> void {
    consume_array(.{7, 8});
}

fn accept_nested_struct_array_literal() -> u32 {
    let cells: [2]Cell = .{ .{ .value = 9 }, .{ .value = 10 } };
    return cells[1].value;
}

fn accept_nested_array_literal() -> u32 {
    let matrix: [2][2]u32 = .{ .{ 5, 6 }, .{ 7, 8 } };
    return matrix[0][1];
}

fn accept_global_nested_array_element() -> u32 {
    return default_matrix[1][0];
}

fn reject_bool_array_length() -> void {
    // EXPECT_ERROR: E_ARRAY_LENGTH_TYPE
    var xs: [false]u8 = uninit;
}

fn reject_targetless_array_literal() -> void {
    // EXPECT_ERROR: E_ARRAY_LITERAL_REQUIRES_TARGET
    let xs = .{1, 2};
}

fn reject_short_array_literal() -> [2]u32 {
    // EXPECT_ERROR: E_ARRAY_LITERAL_LENGTH
    return .{1};
}

fn reject_long_array_literal() -> [2]u32 {
    // EXPECT_ERROR: E_ARRAY_LITERAL_LENGTH
    return .{1, 2, 3};
}

fn reject_array_literal_element_type() -> [2]u32 {
    // EXPECT_ERROR: E_RETURN_TYPE_MISMATCH
    return .{1, null};
}
