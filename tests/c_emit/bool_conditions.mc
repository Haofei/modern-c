extern fn next_value() -> u32;
extern fn consume_bool(value: bool) -> void;

fn bool_not(flag: bool) -> bool {
    return !flag;
}

fn bool_and(a: bool, b: bool) -> bool {
    return a && b;
}

fn bool_or(a: bool, b: bool) -> bool {
    return a || b;
}

fn compare_numbers(a: u32, b: u32) -> bool {
    return a <= b;
}

fn compare_eq(a: u32, b: u32) -> bool {
    return a == b;
}

fn require_complex(a: u32, b: u32, flag: bool) -> void {
    assert(flag && (a == b || a != 0));
}

fn assert_ordered_comparison() -> void {
    assert(next_value() == next_value());
}

fn while_bool(flag: bool) -> u32 {
    var n: u32 = 0;
    while flag {
        n = n + 1;
        break;
    }
    return n;
}

fn while_comparison(n: u32) -> u32 {
    var x: u32 = n;
    while x > 0 {
        x = x - 1;
    }
    return x;
}

fn while_ordered_comparison() -> u32 {
    var x: u32 = 0;
    while next_value() != next_value() {
        x = x + 1;
        break;
    }
    return x;
}

fn return_ordered_comparison() -> bool {
    return next_value() == next_value();
}

fn local_ordered_comparison() -> bool {
    let value: bool = next_value() != next_value();
    return value;
}

fn inferred_local_ordered_comparison() -> bool {
    let value = next_value() < next_value();
    return value;
}

fn assignment_ordered_comparison() -> bool {
    var value: bool = false;
    value = next_value() <= next_value();
    return value;
}

fn arg_ordered_comparison() -> void {
    consume_bool(next_value() >= next_value());
}
