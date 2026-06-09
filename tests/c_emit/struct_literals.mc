struct Pair {
    left: u32,
    right: u32,
}

global default_pair: Pair = .{ .left = 1, .right = 2 };

extern fn consume_pair(pair: Pair) -> void;

fn make_pair() -> Pair {
    return .{ .left = 1, .right = 2 };
}

fn local_pair() -> u32 {
    let pair: Pair = .{ .left = 3, .right = 4 };
    return pair.right;
}

fn assign_pair() -> Pair {
    var pair: Pair = uninit;
    pair = .{ .left = 5, .right = 6 };
    return pair;
}

fn call_pair() -> void {
    consume_pair(.{ .left = 7, .right = 8 });
}
