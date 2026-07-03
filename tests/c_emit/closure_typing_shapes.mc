// Backend evidence for the accepted closure-typing shapes from
// tests/spec/closure_typing.mc: pointer env bind, scalar env bind, closure
// parameter passing, returning a closure bound to a pointer parameter, and
// calling each resulting closure value.

struct Env {
    base: u32,
}

fn add_env(env: *Env, x: u32) -> u32 {
    return env.base + x;
}

fn add_scalar(env: u32, x: u32) -> u32 {
    return env + x;
}

fn accept_bind_and_call() -> u32 {
    var env: Env = .{ .base = 3 };
    let cb: closure(u32) -> u32 = bind(&env, add_env);
    return cb(4);
}

fn accept_scalar_env_bind() -> u32 {
    let cb: closure(u32) -> u32 = bind(10, add_scalar);
    return cb(5);
}

fn accept_closure_param(cb: closure(u32) -> u32, x: u32) -> u32 {
    return cb(x);
}

fn accept_return_closure_bound_to_param(env: *Env) -> closure(u32) -> u32 {
    return bind(env, add_env);
}

fn pass_pointer_env_closure() -> u32 {
    var env: Env = .{ .base = 20 };
    let cb: closure(u32) -> u32 = bind(&env, add_env);
    return accept_closure_param(cb, 6);
}

fn pass_scalar_env_closure() -> u32 {
    let cb: closure(u32) -> u32 = bind(30, add_scalar);
    return accept_closure_param(cb, 7);
}

fn call_returned_closure() -> u32 {
    var env: Env = .{ .base = 40 };
    let cb: closure(u32) -> u32 = accept_return_closure_bound_to_param(&env);
    return cb(8);
}

export fn closure_typing_shapes_run() -> u32 {
    if accept_bind_and_call() != 7 { return 0; }
    if accept_scalar_env_bind() != 15 { return 0; }
    if pass_pointer_env_closure() != 26 { return 0; }
    if pass_scalar_env_closure() != 37 { return 0; }
    if call_returned_closure() != 48 { return 0; }
    return 1;
}
