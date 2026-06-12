struct Pair {
    left: u32,
    right: u32,
}

fn make_pair() -> Pair {
    return .{ .left = 7, .right = 8 };
}

fn take_pair(pair: Pair) -> u32 {
    return pair.right;
}

fn pass_pair() -> u32 {
    return take_pair(make_pair());
}

fn make_row() -> [2]u32 {
    return .{ 9, 10 };
}

fn take_row(row: [2]u32) -> u32 {
    return row[1];
}

fn pass_row() -> u32 {
    return take_row(make_row());
}
