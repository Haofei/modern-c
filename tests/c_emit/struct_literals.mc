struct Pair {
    left: u32,
    right: u32,
}

struct PairBox {
    pair: Pair,
}

global default_pair: Pair = .{ .left = 1, .right = 2 };

fn consume_pair(pair: Pair) -> void {
    let left: u32 = pair.left;
    if left == 0 {
        return;
    }
    return;
}

fn make_pair() -> Pair {
    return .{ .left = 1, .right = 2 };
}

fn make_pair_box() -> PairBox {
    return .{ .pair = .{ .left = 9, .right = 10 } };
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

fn inferred_call_field_pair() -> u32 {
    let pair = make_pair_box().pair;
    return pair.right;
}
