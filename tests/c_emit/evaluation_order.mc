extern fn next_value() -> u32;
extern fn box_value(value: u32) -> u32;
extern fn combine(left: u32, right: u32) -> u32;
extern fn combine3(a: u32, b: u32, c: u32) -> u32;
extern fn consume(left: u32, right: u32) -> void;
extern fn next_wrap() -> wrap<u32>;
extern fn box_wrap(value: wrap<u32>) -> wrap<u32>;
extern fn next_sat() -> sat<u32>;
extern fn box_sat(value: sat<u32>) -> sat<u32>;

global ordered_global: u32 = 0;

fn ordered_two_args() -> u32 {
    return combine(next_value(), next_value());
}

fn ordered_three_args() -> u32 {
    return combine3(next_value(), next_value(), next_value());
}

fn ordered_local_init() -> u32 {
    let value = combine(next_value(), next_value());
    return value;
}

fn ordered_typed_local_init() -> u32 {
    let value: u32 = combine(next_value(), next_value());
    return value;
}

fn ordered_expr_stmt() -> void {
    consume(next_value(), next_value());
}

fn ordered_nested_return() -> u32 {
    return combine(box_value(next_value()), next_value());
}

fn ordered_nested_local_init() -> u32 {
    let value = combine(box_value(next_value()), next_value());
    return value;
}

fn ordered_nested_expr_stmt() -> void {
    consume(box_value(next_value()), next_value());
}

fn ordered_assignment() -> u32 {
    var value: u32 = 0;
    value = combine(next_value(), next_value());
    return value;
}

fn ordered_nested_assignment() -> u32 {
    var value: u32 = 0;
    value = combine(box_value(next_value()), next_value());
    return value;
}

fn ordered_global_assignment() -> void {
    ordered_global = combine(next_value(), next_value());
}

fn ordered_checked_return() -> u32 {
    return next_value() + next_value();
}

fn ordered_checked_nested_return() -> u32 {
    return box_value(next_value()) + next_value();
}

fn ordered_checked_local_init() -> u32 {
    let value = next_value() + next_value();
    return value;
}

fn ordered_checked_typed_local_init() -> u32 {
    let value: u32 = next_value() + next_value();
    return value;
}

fn ordered_checked_assignment() -> u32 {
    var value: u32 = 0;
    value = next_value() + next_value();
    return value;
}

fn ordered_checked_global_assignment() -> void {
    ordered_global = next_value() + next_value();
}

fn ordered_wrap_shift_return() -> wrap<u32> {
    return next_wrap() << next_wrap();
}

fn ordered_wrap_nested_return() -> wrap<u32> {
    return box_wrap(next_wrap()) + next_wrap();
}

fn ordered_wrap_assignment() -> wrap<u32> {
    var value: wrap<u32> = 0;
    value = next_wrap() << next_wrap();
    return value;
}

fn ordered_sat_return() -> sat<u32> {
    return next_sat() + next_sat();
}

fn ordered_sat_nested_return() -> sat<u32> {
    return box_sat(next_sat()) * next_sat();
}

fn ordered_sat_assignment() -> sat<u32> {
    var value: sat<u32> = 0;
    value = next_sat() + next_sat();
    return value;
}
