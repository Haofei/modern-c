extern fn close_resource() -> void;

fn lexical_cleanup() -> void {
    defer close_resource();
    return;
}

fn block_lexical_cleanup() -> void {
    defer {
        close_resource();
    };
    return;
}

fn cleanup_before_fallthrough() -> void {
    defer close_resource();
}

fn cleanup_before_break(flag: bool) -> void {
    while flag {
        defer close_resource();
        break;
    }
}

fn cleanup_before_continue(flag: bool) -> void {
    while flag {
        defer close_resource();
        continue;
    }
}
