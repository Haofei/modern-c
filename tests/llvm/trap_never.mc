extern fn consume_u32(value: u32) -> void;

fn trap_as_value() -> u32 {
    return trap(.Bounds);
}

fn unreachable_as_value() -> u32 {
    return unreachable;
}

fn unreachable_statement() -> void {
    unreachable;
}

fn never_returns_by_trap() -> never {
    return trap(.Assert);
}

fn explicit_empty_return() -> void {
    return;
}

fn fallthrough_void() -> void {
    consume_u32(1);
}

fn unit_return() -> void {
    return ();
}

fn never_return_from_void() -> void {
    return trap(.Assert);
}

fn call_void(value: u32) -> void {
    consume_u32(value);
    return;
}
