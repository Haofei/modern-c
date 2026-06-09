global default_values: [2]u32 = .{1, 2};

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
