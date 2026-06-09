extern fn consume_u32(value: u32) -> void;

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
