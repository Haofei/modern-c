fn local_array() -> u32 {
    let xs: [2]u32 = .{ 11, 22 };
    return xs[1];
}

fn assign_array_element(value: u32) -> u32 {
    var xs: [2]u32 = .{ 1, 2 };
    xs[0] = value;
    return xs[0];
}

fn address_array_element(value: u32) -> u32 {
    var xs: [2]u32 = .{ 3, 4 };
    let p: *mut u32 = &xs[1];
    *p = value;
    return xs[1];
}
