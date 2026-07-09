// SPEC: section=18.1
// SPEC: milestone=linear-move
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_RESOURCE_LEAK,E_MOVE_FIELD_IN_NONMOVE

// Regression coverage for the move checker's control-flow model (section 18.1):
//   * `?` is an exit edge — on its error branch the function returns, so any other
//     live `move` value leaks there unless consumed first or registered with `defer`.
//   * An early `return` inside a branch is an exit edge for the *whole* live set, and a
//     branch that diverges is not merged into the join (no spurious branch mismatch).
//   * A `move` resource may not be stored by value in a non-`move` aggregate, where it
//     would escape linear tracking (this also rejects a generic container over a move
//     type, which monomorphizes to exactly such a struct).
//
// The fail-closed E_MOVE_ARRAY_UNSUPPORTED reject cases (arrays of `move` resources in
// every position) live in tests/spec/bad/move_cfg_arrays_reject.mc: several are top-level
// declarations whose trailing reject markers fall after the chunk-ending `;`, so the
// sweeps' chunk-level strip cannot isolate them and they need a pure-reject fixture
// the sweeps do not compile.

move struct Handle { v: u32 }
type HandleArray = [2]Handle;
move struct HandleBox { items: [2]Handle }
enum E { Bad }
fn acquire() -> Handle {
    return .{ .v = 1 };
}
fn release(h: Handle) -> u32 {
    let v: u32 = h.v;
    unsafe { forget_unchecked(h); }
    return v;
}
extern fn risky() -> Result<u32, E>;
fn acquire_box() -> HandleBox {
    return .{ .items = .{ acquire(), acquire() } };
}

// --- accepted: the `?` error edge is covered by a defer ---
fn accept_try_defer() -> Result<u32, E> {
    let h: Handle = acquire();
    defer release(h);
    let x: u32 = risky()?;
    return ok(x);
}

// --- accepted: the resource is consumed before the `?` ---
fn accept_consume_before_try() -> Result<u32, E> {
    let h: Handle = acquire();
    let r: u32 = release(h);
    let x: u32 = risky()?;
    return ok(r + x);
}

// --- accepted: one branch diverges (returns) after consuming, the other consumes ---
fn accept_diverging_branch(cond: bool) -> u32 {
    let h: Handle = acquire();
    if cond {
        release(h);
        return 0;
    }
    return release(h);
}

// --- rejected: a live resource leaks on the `?` error branch ---
fn reject_try_leak() -> Result<u32, E> {
    // EXPECT_ERROR: E_RESOURCE_LEAK
    let h: Handle = acquire();
    let x: u32 = risky()?;
    let r: u32 = release(h);
    return ok(r + x);
}

// --- rejected: `?` leak checks include constant-index array subplaces ---
fn reject_try_after_array_element_move() -> Result<u32, E> {
    let arr: HandleArray = .{ acquire(), acquire() }; // EXPECT_ERROR: E_RESOURCE_LEAK
    let first: Handle = arr[0]; // EXPECT_ERROR: E_RESOURCE_LEAK
    let x: u32 = risky()?;
    let r: u32 = release(first);
    unsafe { forget_unchecked(arr); }
    return ok(r + x);
}

// --- rejected: `?` leak checks include wildcard dynamic array subplaces ---
fn reject_try_after_dynamic_array_element_move(i: usize) -> Result<u32, E> {
    let arr: HandleArray = .{ acquire(), acquire() }; // EXPECT_ERROR: E_RESOURCE_LEAK
    let moved: Handle = arr[i]; // EXPECT_ERROR: E_RESOURCE_LEAK
    let x: u32 = risky()?;
    let r: u32 = release(moved);
    unsafe { forget_unchecked(arr); }
    return ok(r + x);
}

// --- rejected: `?` leak checks include move-struct array field subplaces ---
fn reject_try_after_array_field_element_move() -> Result<u32, E> {
    let box: HandleBox = acquire_box(); // EXPECT_ERROR: E_RESOURCE_LEAK
    let first: Handle = box.items[0]; // EXPECT_ERROR: E_RESOURCE_LEAK
    let x: u32 = risky()?;
    let r: u32 = release(first);
    unsafe { forget_unchecked(box); }
    return ok(r + x);
}

// --- rejected: `?` leak checks include dynamic move-struct array field subplaces ---
fn reject_try_after_dynamic_array_field_element_move(i: usize) -> Result<u32, E> {
    let box: HandleBox = acquire_box(); // EXPECT_ERROR: E_RESOURCE_LEAK
    let moved: Handle = box.items[i]; // EXPECT_ERROR: E_RESOURCE_LEAK
    let x: u32 = risky()?;
    let r: u32 = release(moved);
    unsafe { forget_unchecked(box); }
    return ok(r + x);
}

// --- rejected: a resource leaks on an early-`return` branch (the other path consumes) ---
fn reject_branch_return_leak(cond: bool) -> u32 {
    // EXPECT_ERROR: E_RESOURCE_LEAK
    let h: Handle = acquire();
    if cond {
        return 0;
    }
    return release(h);
}

// --- accepted: a `move` resource may live inside another `move` aggregate ---
move struct GoodPair {
    a: Handle,
    b: Handle,
}

// --- rejected: a `move` resource stored by value in a non-`move` struct ---
struct BadContainer {
    // EXPECT_ERROR: E_MOVE_FIELD_IN_NONMOVE
    h: Handle,
}
