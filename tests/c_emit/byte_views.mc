extern struct Pair {
    tag: u8,
    value: u32,
}

fn as_bytes_index() -> u8 {
    var pair: Pair = .{ .tag = 1, .value = 0xAABBCCDD };
    let bytes = mem.as_bytes(&pair);
    return bytes[0];
}

fn bytes_equal_pair() -> bool {
    var a: Pair = .{ .tag = 1, .value = 2 };
    var b: Pair = .{ .tag = 1, .value = 2 };
    return mem.bytes_equal(mem.as_bytes(&a), mem.as_bytes(&b));
}

fn bytes_equal_local_slices() -> bool {
    var a: Pair = .{ .tag = 3, .value = 4 };
    var b: Pair = .{ .tag = 3, .value = 5 };
    let left = mem.as_bytes(&a);
    let right = mem.as_bytes(&b);
    return mem.bytes_equal(left, right);
}
