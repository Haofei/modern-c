extern fn make_array() -> [2]u32;
extern fn consume_array(xs: [2]u32) -> void;

fn return_call_array() -> [2]u32 {
    return make_array();
}

fn copy_array(xs: [2]u32) -> [2]u32 {
    let ys: [2]u32 = xs;
    return ys;
}

fn pass_array_value() -> void {
    let xs = make_array();
    consume_array(xs);
}

fn read_copied_array(xs: [2]u32, i: usize) -> u32 {
    let ys: [2]u32 = xs;
    return ys[i];
}
