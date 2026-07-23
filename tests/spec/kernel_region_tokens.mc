// SPEC: section=18,31
// SPEC: milestone=kernel-region-tokens
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_USE_AFTER_MOVE,E_RESOURCE_LEAK

// Restricted kernel regions are represented by linear capability tokens.  A
// pointer returned from a function that borrows a token carries that token's
// MovePlace, so consuming the token invalidates the derived pointer.  This is a
// bounded Guard/RCU/Registration lifetime model, not general lifetime inference.

move struct RcuReadGuard {
    epoch: *const u32,
}

move struct CallbackRegistration {
    data: *mut u32,
}

fn rcu_read_lock(epoch: *const u32) -> RcuReadGuard {
    return .{ .epoch = epoch };
}

fn rcu_lookup(guard: *RcuReadGuard) -> *const u32 {
    return guard.epoch;
}

fn rcu_read_unlock(guard: RcuReadGuard) -> void {
    unsafe { forget_unchecked(guard); }
}

fn register_callback(data: *mut u32) -> CallbackRegistration {
    return .{ .data = data };
}

fn callback_data(registration: *CallbackRegistration) -> *mut u32 {
    return registration.data;
}

fn unregister_callback(registration: CallbackRegistration) -> void {
    unsafe { forget_unchecked(registration); }
}

fn accept_rcu_use_inside_region(epoch: *const u32) -> u32 {
    let guard: RcuReadGuard = rcu_read_lock(epoch);
    let value: u32 = rcu_lookup(&guard).*;
    rcu_read_unlock(guard);
    return value;
}

fn reject_rcu_reference_escape(epoch: *const u32) -> u32 {
    let guard: RcuReadGuard = rcu_read_lock(epoch);
    let value: *const u32 = rcu_lookup(&guard);
    rcu_read_unlock(guard);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return value.*;
}

fn accept_callback_data_while_registered(data: *mut u32) -> u32 {
    let registration: CallbackRegistration = register_callback(data);
    let value: u32 = callback_data(&registration).*;
    unregister_callback(registration);
    return value;
}

fn reject_callback_data_after_unregister(data: *mut u32) -> u32 {
    let registration: CallbackRegistration = register_callback(data);
    let value: *mut u32 = callback_data(&registration);
    unregister_callback(registration);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    return value.*;
}

fn reject_leaked_registration(data: *mut u32) -> void {
    // EXPECT_ERROR: E_RESOURCE_LEAK
    let registration: CallbackRegistration = register_callback(data);
}
