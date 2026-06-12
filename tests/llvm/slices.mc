extern fn make_u8_slice() -> []const u8;
extern fn make_u8_array() -> [4]u8;
extern fn make_u8_slice_from(seed: u8) -> []const u8;
extern fn next_byte() -> u8;
extern fn next_index() -> usize;

fn read_slice(xs: []const u8, i: usize) -> u8 {
    return xs[i];
}

fn read_literal(xs: []const u8) -> u8 {
    return xs[0];
}

fn write_slice(xs: []mut u32, i: usize, value: u32) -> void {
    xs[i] = value;
    return;
}

fn same_slice(xs: []const u8) -> []const u8 {
    return xs;
}

fn slice_len(xs: []const u8) -> usize {
    return xs.len;
}

fn slice_from_array(n: usize) -> u8 {
    var buf: [4]u8 = .{ 1, 2, 3, 4 };
    let s: []mut u8 = buf[1..n];
    return s[0];
}

fn slice_from_slice(xs: []const u8, lo: usize, hi: usize) -> usize {
    let s: []const u8 = xs[lo..hi];
    return s.len;
}

fn direct_call_slice() -> u8 {
    return make_u8_slice()[0];
}

fn inferred_slice_call_base_arg() -> u8 {
    let xs = make_u8_slice_from(next_byte());
    return xs[next_index()];
}

fn inferred_array_call_base() -> u8 {
    let xs = make_u8_array();
    return xs[next_index()];
}
