struct Pair {
    left: u32,
    right: u32,
}

struct MatrixBox {
    rows: [2][2]u32,
}

struct RowBox {
    row: [2]u32,
}

global matrix: [2][2]u32 = .{ .{ 1, 2 }, .{ 3, 4 } };
global box: MatrixBox = .{ .rows = .{ .{ 5, 6 }, .{ 7, 8 } } };
global row_boxes: [2]RowBox = .{ .{ .row = .{ 9, 10 } }, .{ .row = .{ 11, 12 } } };
global default_pair: Pair = .{ .left = 13, .right = 14 };

extern fn consume_row(row: [2]u32) -> u32;

fn consume_pair(pair: Pair) -> u32 {
    return pair.left + pair.right;
}

fn assign_array_literal() -> [2]u32 {
    var xs: [2]u32 = uninit;
    xs = .{ 21, 22 };
    return xs;
}

fn local_array_copy() -> u32 {
    let row: [2]u32 = matrix[1];
    return row[0];
}

fn assign_global_nested_array_row() -> u32 {
    matrix[1] = .{ 31, 32 };
    return matrix[1][1];
}

fn assign_struct_field_nested_array_row() -> u32 {
    box.rows[0] = .{ 41, 42 };
    return box.rows[0][1];
}

fn assign_array_struct_field_array() -> u32 {
    row_boxes[0].row = .{ 51, 52 };
    return row_boxes[0].row[1];
}

fn assign_struct_literal() -> Pair {
    var pair: Pair = uninit;
    pair = .{ .left = 61, .right = 62 };
    return pair;
}

fn local_struct_copy() -> u32 {
    let pair: Pair = default_pair;
    return pair.right;
}

fn aggregate_call_after_assignment() -> u32 {
    var row: [2]u32 = uninit;
    row = matrix[0];
    var pair: Pair = uninit;
    pair = .{ .left = 71, .right = 72 };
    return consume_row(row) + consume_pair(pair);
}
