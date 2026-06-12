extern fn next_value() -> u32;
extern fn consume_bool(value: bool) -> void;

fn bool_and(a: bool, b: bool) -> bool {
    return a && b;
}

fn bool_or(a: bool, b: bool) -> bool {
    return a || b;
}

fn nested_bool(a: bool, b: bool, c: bool) -> bool {
    return !a || (b && c);
}

fn require_complex(a: u32, b: u32, flag: bool) -> void {
    assert(flag && (a == b || a != 0));
}

fn assert_ordered_comparison() -> void {
    assert(next_value() == next_value());
}

fn bool_arg(a: bool, b: bool) -> void {
    consume_bool(a || b);
}
