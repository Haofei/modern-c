extern fn make_u8_slice() -> []const u8;

fn slice_usize_index(buf: []const u8, i: usize) -> u8 {
    return buf[i];
}

fn slice_literal_index(buf: []const u8) -> u8 {
    return buf[0];
}

fn array_usize_index(buf: [4]u8, i: usize) -> u8 {
    return buf[i];
}

fn direct_call_slice_index() -> u8 {
    return make_u8_slice()[0];
}
