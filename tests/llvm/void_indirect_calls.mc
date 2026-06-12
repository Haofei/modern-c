struct Env {
    value: u32,
}

fn tick() -> void {}

fn entry_of() -> fn() -> void {
    return tick;
}

fn call_fn_pointer() -> void {
    let entry: fn() -> void = entry_of();
    entry();
}

fn store_value(env: *mut Env, value: u32) -> void {
    env.value = value;
}

fn call_closure(value: u32) -> void {
    var env: Env = .{ .value = 0 };
    let set: closure(u32) -> void = bind(&env, store_value);
    set(value);
}
