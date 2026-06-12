struct Pair {
    left: u32,
    right: u32,
}

struct Box {
    pair: Pair,
}

global matrix: [2][2]u32 = .{ .{ 1, 2 }, .{ 3, 4 } };
global box: Box = .{ .pair = .{ .left = 5, .right = 6 } };

fn local_nested_array() -> u32 {
    let xs: [2][2]u32 = .{ .{ 7, 8 }, .{ 9, 10 } };
    return xs[1][0];
}

fn assign_nested_array(value: u32) -> u32 {
    var xs: [2][2]u32 = .{ .{ 1, 2 }, .{ 3, 4 } };
    xs[0][1] = value;
    return xs[0][1];
}

fn global_nested_array() -> u32 {
    matrix[1][0] = 11;
    return matrix[1][0];
}

fn local_nested_struct(value: u32) -> u32 {
    var b: Box = .{ .pair = .{ .left = 1, .right = 2 } };
    b.pair.right = value;
    return b.pair.right;
}

fn global_nested_struct(value: u32) -> u32 {
    box.pair.left = value;
    return box.pair.left;
}

fn take_box(b: Box) -> u32 {
    return b.pair.right;
}
