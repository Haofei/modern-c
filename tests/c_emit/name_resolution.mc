global known_global: u32 = 1;

extern fn known_external(value: u32) -> u32;

fn known_value() -> u32 {
    return 1;
}

fn resolve_global_and_call(value: u32) -> u32 {
    let local = known_value();
    known_global = known_external(value);
    return known_global + local;
}

fn resolve_assignment_target(value: u32) -> void {
    known_global = value;
}
