extern fn close_a() -> void;
extern fn close_b() -> void;
extern fn next_value() -> u32;
extern fn close_pair(left: u32, right: u32) -> void;

fn cleanup_before_return() -> u32 {
    defer close_a();
    defer close_b();
    return 1;
}

fn cleanup_args_before_return() -> u32 {
    defer close_pair(next_value(), next_value());
    return 1;
}

fn cleanup_before_fallthrough() -> void {
    defer close_a();
}

fn cleanup_before_break(flag: bool) -> void {
    while flag {
        defer close_a();
        break;
    }
}

fn cleanup_before_continue(flag: bool) -> void {
    while flag {
        defer close_a();
        continue;
    }
}

fn cleanup_block_before_return() -> u32 {
    defer {
        close_a();
        close_b();
    };
    return 1;
}
