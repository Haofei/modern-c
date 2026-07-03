// SPEC: section=15,22
// SPEC: milestone=closures
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_CALL_ARG_COUNT,E_CLOSURE_SIGNATURE_MISMATCH,E_NO_IMPLICIT_CONVERSION

struct Env {
    base: u32,
}

fn add_env(env: *Env, x: u32) -> u32 {
    return env.base + x;
}

fn wrong_arg(env: *Env, x: u64) -> u32 {
    return x as u32;
}

fn wrong_ret(env: *Env, x: u32) -> u64 {
    return (env.base + x) as u64;
}

fn no_env(x: u32) -> u32 {
    return x;
}

fn accept_bind_and_call() -> u32 {
    var env: Env = .{ .base = 3 };
    let cb: closure(u32) -> u32 = bind(&env, add_env);
    return cb(4);
}

fn accept_closure_param(cb: closure(u32) -> u32) -> u32 {
    return cb(5);
}

fn reject_closure_call_arity(cb: closure(u32) -> u32) -> u32 {
    // EXPECT_ERROR: E_CALL_ARG_COUNT
    return cb();
}

fn reject_closure_call_arg_type(cb: closure(u32) -> u32) -> u32 {
    // EXPECT_ERROR: E_NO_IMPLICIT_CONVERSION
    return cb(1 as u64);
}

fn reject_bind_arg_signature() -> void {
    var env: Env = .{ .base = 1 };
    // EXPECT_ERROR: E_CLOSURE_SIGNATURE_MISMATCH
    let cb: closure(u32) -> u32 = bind(&env, wrong_arg);
}

fn reject_bind_return_signature() -> void {
    var env: Env = .{ .base = 1 };
    // EXPECT_ERROR: E_CLOSURE_SIGNATURE_MISMATCH
    let cb: closure(u32) -> u32 = bind(&env, wrong_ret);
}

fn reject_bind_missing_env_param() -> void {
    var env: Env = .{ .base = 1 };
    // EXPECT_ERROR: E_CLOSURE_SIGNATURE_MISMATCH
    let cb: closure() -> u32 = bind(&env, no_env);
}
