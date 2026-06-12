global default_values: [2]u32 = .{1, 2};

struct Cell {
    value: u32,
}

global default_cells: [2]Cell = .{ .{ .value = 1 }, .{ .value = 2 } };
global default_matrix: [2][2]u32 = .{ .{ 1, 2 }, .{ 3, 4 } };

extern fn consume_array(xs: [2]u32) -> void;

fn make_literal() -> [2]u32 {
    return .{1, 2};
}

fn local_literal() -> u32 {
    let xs: [2]u32 = .{1, 2};
    return xs[1];
}

fn assign_literal() -> [2]u32 {
    var xs: [2]u32 = uninit;
    xs = .{3, 4};
    return xs;
}

fn call_literal() -> void {
    consume_array(.{5, 6});
}

fn const_expr_length() -> u32 {
    let xs: [1 + 2]u32 = .{10, 20, 30};
    return xs[2];
}

fn nested_struct_array_literal() -> u32 {
    let cells: [2]Cell = .{ .{ .value = 9 }, .{ .value = 10 } };
    return cells[1].value;
}

fn nested_array_literal() -> u32 {
    let matrix: [2][2]u32 = .{ .{ 5, 6 }, .{ 7, 8 } };
    return matrix[0][1];
}

fn global_nested_array_element() -> u32 {
    return default_matrix[1][0];
}

fn global_nested_array_copy() -> [2][2]u32 {
    return default_matrix;
}
