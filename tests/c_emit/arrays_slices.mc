fn array_first() -> u8 {
    var buf: [4]u8 = uninit;
    buf[0] = 7;
    return buf[0];
}

fn slice_first(buf: []const u8) -> u8 {
    return buf[0];
}

fn slice_at(buf: []const u8, index: usize) -> u8 {
    return buf[index];
}

extern fn make_slice() -> []const u8;
extern fn make_array() -> [4]u8;
extern fn make_slice_from(seed: u8) -> []const u8;
extern fn make_array_from(seed: u8) -> [4]u8;
extern fn next_byte() -> u8;
extern fn next_index() -> usize;
extern fn consume_byte(value: u8) -> void;

fn direct_call_slice_index_return() -> u8 {
    return make_slice()[next_index()];
}

fn direct_call_slice_index_local() -> u8 {
    let value: u8 = make_slice()[next_index()];
    return value;
}

fn direct_call_slice_index_assignment() -> u8 {
    var value: u8 = 0;
    value = make_slice()[next_index()];
    return value;
}

fn direct_call_slice_index_arg() -> void {
    consume_byte(make_slice()[next_index()]);
}

fn direct_call_slice_index_base_arg() -> u8 {
    return make_slice_from(next_byte())[next_index()];
}

fn inferred_slice_call_base_arg() -> u8 {
    let xs = make_slice_from(next_byte());
    return xs[next_index()];
}

fn local_slice_index_return(xs: []const u8) -> u8 {
    return xs[next_index()];
}

fn local_slice_index_local(xs: []const u8) -> u8 {
    let value: u8 = xs[next_index()];
    return value;
}

fn local_slice_index_assignment(xs: []const u8) -> u8 {
    var value: u8 = 0;
    value = xs[next_index()];
    return value;
}

fn local_slice_index_arg(xs: []const u8) -> void {
    consume_byte(xs[next_index()]);
}

fn local_slice_index_target_index(xs: []mut u8, value: u8) -> void {
    xs[next_index()] = value;
}

fn local_slice_index_target_value(xs: []mut u8, index: usize) -> void {
    xs[index] = next_byte();
}

fn local_slice_index_target_both(xs: []mut u8) -> void {
    xs[next_index()] = next_byte();
}

fn direct_call_array_index_return() -> u8 {
    return make_array()[next_index()];
}

fn direct_call_array_index_local() -> u8 {
    let value: u8 = make_array()[next_index()];
    return value;
}

fn direct_call_array_index_assignment() -> u8 {
    var value: u8 = 0;
    value = make_array()[next_index()];
    return value;
}

fn direct_call_array_index_arg() -> void {
    consume_byte(make_array()[next_index()]);
}

fn direct_call_array_index_base_arg() -> u8 {
    return make_array_from(next_byte())[next_index()];
}

fn inferred_array_call_base_arg() -> u8 {
    let xs = make_array_from(next_byte());
    return xs[next_index()];
}

fn local_array_index_return(xs: [4]u8) -> u8 {
    return xs[next_index()];
}

fn local_array_index_local(xs: [4]u8) -> u8 {
    let value: u8 = xs[next_index()];
    return value;
}

fn local_array_index_assignment(xs: [4]u8) -> u8 {
    var value: u8 = 0;
    value = xs[next_index()];
    return value;
}

fn local_array_index_arg(xs: [4]u8) -> void {
    consume_byte(xs[next_index()]);
}

fn local_array_index_target_index(value: u8) -> void {
    var xs: [4]u8 = uninit;
    xs[next_index()] = value;
}

fn local_array_index_target_value(index: usize) -> void {
    var xs: [4]u8 = uninit;
    xs[index] = next_byte();
}

fn local_array_index_target_both() -> void {
    var xs: [4]u8 = uninit;
    xs[next_index()] = next_byte();
}
