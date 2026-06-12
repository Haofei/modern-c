global default_values: [2]u32 = .{1, 2};
const WORD_SIZE: usize = sizeof(u32);

extern struct Packet {
    len: u16,
    tag: u8,
}

const PACKET_SIZE: usize = sizeof(Packet);
const PACKET_TAG_OFFSET: usize = field_offset(Packet, .tag);

struct Cell {
    value: u32,
}

struct MatrixBox {
    rows: [2][2]u32,
}

struct RowBox {
    row: [2]u32,
}

global default_cells: [2]Cell = .{ .{ .value = 1 }, .{ .value = 2 } };
global default_matrix: [2][2]u32 = .{ .{ 1, 2 }, .{ 3, 4 } };
global default_box: MatrixBox = .{ .rows = .{ .{ 1, 2 }, .{ 3, 4 } } };
global default_row_boxes: [2]RowBox = .{ .{ .row = .{ 1, 2 } }, .{ .row = .{ 3, 4 } } };

extern fn consume_array(xs: [2]u32) -> void;
extern fn make_matrix() -> [2][2]u32;
extern fn consume_row(row: [2]u32) -> u32;

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

fn reflected_const_length() -> u8 {
    let xs: [WORD_SIZE]u8 = .{1, 2, 3, 4};
    return xs[3];
}

fn reflected_struct_const_length() -> u8 {
    let xs: [PACKET_SIZE]u8 = .{1, 2, 3, 4};
    return xs[2];
}

fn reflected_field_offset_const_length() -> u8 {
    let xs: [PACKET_TAG_OFFSET]u8 = .{7, 8};
    return xs[1];
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

fn global_nested_array_row() -> [2]u32 {
    return default_matrix[1];
}

fn global_nested_array_row_local() -> u32 {
    let row: [2]u32 = default_matrix[0];
    return row[1];
}

fn inferred_call_nested_array_row() -> u32 {
    let row = make_matrix()[0];
    return consume_row(row);
}

fn assign_global_nested_array_row() -> void {
    default_matrix[1] = .{9, 10};
}

fn global_nested_array_copy() -> [2][2]u32 {
    return default_matrix;
}

fn struct_field_nested_array_element() -> u32 {
    return default_box.rows[1][0];
}

fn struct_field_nested_array_row() -> [2]u32 {
    return default_box.rows[1];
}

fn assign_struct_field_nested_array_element() -> void {
    default_box.rows[1][0] = 9;
}

fn assign_struct_field_nested_array_row() -> void {
    default_box.rows[0] = .{10, 11};
}

fn array_struct_field_array_element() -> u32 {
    return default_row_boxes[1].row[0];
}

fn assign_array_struct_field_array_element() -> void {
    default_row_boxes[1].row[0] = 9;
}

fn assign_array_struct_field_array() -> void {
    default_row_boxes[0].row = .{10, 11};
}
