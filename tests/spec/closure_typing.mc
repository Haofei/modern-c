// SPEC: section=15,22
// SPEC: milestone=closures
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_CALL_ARG_COUNT,E_CLOSURE_SIGNATURE_MISMATCH,E_LOCAL_ADDRESS_ESCAPE,E_NO_IMPLICIT_CONVERSION

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

fn add_scalar(env: u32, x: u32) -> u32 {
    return env + x;
}

global saved_cb: closure(u32) -> u32;

extern fn extern_accept_closure(cb: closure(u32) -> u32) -> void;

fn accept_bind_and_call() -> u32 {
    var env: Env = .{ .base = 3 };
    let cb: closure(u32) -> u32 = bind(&env, add_env);
    return cb(4);
}

fn accept_scalar_env_bind() -> u32 {
    let cb: closure(u32) -> u32 = bind(3, add_scalar);
    return cb(4);
}

fn accept_closure_param(cb: closure(u32) -> u32) -> u32 {
    return cb(5);
}

fn accept_return_closure_bound_to_param(env: *Env) -> closure(u32) -> u32 {
    return bind(env, add_env);
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

fn reject_return_bind_local_env() -> closure(u32) -> u32 {
    var env: Env = .{ .base = 1 };
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return bind(&env, add_env);
}

fn reject_return_bound_local_env() -> closure(u32) -> u32 {
    var env: Env = .{ .base = 1 };
    let cb: closure(u32) -> u32 = bind(&env, add_env);
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return cb;
}

fn reject_assign_bound_local_env_to_global() -> void {
    var env: Env = .{ .base = 1 };
    let cb: closure(u32) -> u32 = bind(&env, add_env);
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    saved_cb = cb;
}

fn reject_assign_bind_local_env_to_global() -> void {
    var env: Env = .{ .base = 1 };
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    saved_cb = bind(&env, add_env);
}

fn reject_store_closure_param_to_global(cb: closure(u32) -> u32) -> void {
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    saved_cb = cb;
}

fn reject_pass_local_env_closure_to_extern() -> void {
    var env: Env = .{ .base = 1 };
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    extern_accept_closure(bind(&env, add_env));
}

fn reject_identity_return_closure_param(cb: closure(u32) -> u32) -> closure(u32) -> u32 {
    // EXPECT_ERROR: E_LOCAL_ADDRESS_ESCAPE
    return cb;
}

fn reject_return_through_identity() -> closure(u32) -> u32 {
    var env: Env = .{ .base = 1 };
    return reject_identity_return_closure_param(bind(&env, add_env));
}
