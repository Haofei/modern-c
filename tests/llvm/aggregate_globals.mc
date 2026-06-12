struct Pair {
    left: u32,
    right: u32,
}

global values: [2]u32 = .{ 10, 20 };
global pair: Pair = .{ .left = 1, .right = 2 };

fn read_global_array() -> u32 {
    return values[1];
}

fn write_global_array(value: u32) -> u32 {
    values[0] = value;
    return values[0];
}

fn read_global_field() -> u32 {
    return pair.right;
}

fn write_global_field(value: u32) -> u32 {
    pair.left = value;
    return pair.left;
}

fn address_global_field(value: u32) -> u32 {
    let p: *mut u32 = &pair.right;
    *p = value;
    return pair.right;
}
