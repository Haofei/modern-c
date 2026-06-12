struct Pair {
    left: u32,
    right: u32,
}

fn read_field() -> u32 {
    let pair: Pair = .{ .left = 3, .right = 4 };
    return pair.right;
}

fn assign_field(value: u32) -> u32 {
    var pair: Pair = .{ .left = 1, .right = 2 };
    pair.left = value;
    return pair.left;
}

fn address_field(value: u32) -> u32 {
    var pair: Pair = .{ .left = 5, .right = 6 };
    let p: *mut u32 = &pair.right;
    *p = value;
    return pair.right;
}
