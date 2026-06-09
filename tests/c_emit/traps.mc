fn trap_as_value() -> u32 {
    return trap(.Bounds);
}

fn unreachable_as_value() -> u32 {
    return unreachable;
}

fn never_returns_by_trap() -> never {
    return trap(.Assert);
}

fn assert_flag(flag: bool) -> void {
    assert(flag);
}
