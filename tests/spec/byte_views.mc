// SPEC: section=14
// SPEC: milestone=byte-views
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_BYTE_VIEW_ADDRESS,E_BYTE_VIEW_SLICE

extern struct Pair {
    tag: u8,
    value: u32,
}

extern fn make_words() -> []const u32;

fn accept_as_bytes_index() -> u8 {
    var pair: Pair = .{ .tag = 1, .value = 0xAABBCCDD };
    let bytes = mem.as_bytes(&pair);
    return bytes[0];
}

fn accept_bytes_equal() -> bool {
    var a: Pair = .{ .tag = 1, .value = 2 };
    var b: Pair = .{ .tag = 1, .value = 2 };
    return mem.bytes_equal(mem.as_bytes(&a), mem.as_bytes(&b));
}

fn reject_as_bytes_value() -> []const u8 {
    var pair: Pair = .{ .tag = 1, .value = 2 };
    // EXPECT_ERROR: E_BYTE_VIEW_ADDRESS
    return mem.as_bytes(pair);
}

fn reject_bytes_equal_non_byte_slice() -> bool {
    var pair: Pair = .{ .tag = 1, .value = 2 };
    // EXPECT_ERROR: E_BYTE_VIEW_SLICE
    return mem.bytes_equal(make_words(), mem.as_bytes(&pair));
}
