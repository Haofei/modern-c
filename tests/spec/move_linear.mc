// SPEC: section=18.1
// SPEC: milestone=linear-move
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_USE_AFTER_MOVE,E_RESOURCE_LEAK,E_RESOURCE_OVERWRITE,E_MOVE_BRANCH_MISMATCH,E_MOVE_LOOP_RESOURCE,E_UNUSED_MOVE_RESULT

// Linear `move` resource types (section 18.1): a `move` value is used linearly —
// consumed (moved) exactly once. A by-value use moves it; `&x` borrows.

move struct Token {
    v: u32,
}

extern fn make() -> Token;
extern fn consume(t: Token) -> u32;
extern fn relabel(t: Token) -> Token;
extern fn peek(t: *Token) -> u32;

// --- accepted: each move value consumed exactly once ---

fn accept_consume_once() -> u32 {
    let t: Token = make();
    return consume(t);
}

fn accept_transition_distinct() -> u32 {
    let a: Token = make();
    let b: Token = relabel(a); // a moved into relabel; b is the new handle
    return consume(b);
}

fn accept_borrow_then_consume() -> u32 {
    let t: Token = make();
    let x: u32 = peek(&t); // &t borrows, does not consume
    return consume(t) + x;
}

// --- rejected ---

fn reject_use_after_move() -> u32 {
    let t: Token = make();
    let a: u32 = consume(t);
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let b: u32 = consume(t);
    return a + b;
}

fn reject_leak() -> u32 {
    // EXPECT_ERROR: E_RESOURCE_LEAK
    let t: Token = make();
    return 0;
}

fn reject_copy() -> u32 {
    let t: Token = make();
    let x: Token = t;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Token = t;
    return consume(x) + consume(y);
}

fn reject_overwrite_live() -> u32 {
    var t: Token = make();
    // EXPECT_ERROR: E_RESOURCE_OVERWRITE
    t = make();
    return consume(t);
}

fn reject_branch_mismatch(flag: bool) -> u32 {
    // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
    let t: Token = make();
    switch flag {
        true => { let a: u32 = consume(t); }
        false => { }
    }
    return 0;
}

fn reject_return_path_leak(flag: bool) -> u32 {
    let t: Token = make(); // EXPECT_ERROR: E_RESOURCE_LEAK
    switch flag {
        true => { return 0; }
        false => { return consume(t); }
    }
}

fn reject_branch_local_leak(flag: bool) -> u32 {
    switch flag {
        true => {
            let t: Token = make(); // EXPECT_ERROR: E_RESOURCE_LEAK
        }
        false => { }
    }
    return 0;
}

fn reject_loop_outer_move(flag: bool) -> u32 {
    let t: Token = make(); // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
    while flag {
        let a: u32 = consume(t);
    }
    return 0;
}

// A loop-body-local move value that is live when `break` exits the iteration leaks
// on that edge — the iteration ends without consuming it.
fn reject_loop_break_leak(flag: bool) -> u32 {
    while flag {
        let t: Token = make(); // EXPECT_ERROR: E_RESOURCE_LEAK
        if flag {
            break;             // t leaks on the break edge
        }
        let a: u32 = consume(t);
    }
    return 0;
}

// Same for `continue`: a live body-local at the continue edge leaks.
fn reject_loop_continue_leak(flag: bool) -> u32 {
    while flag {
        let t: Token = make(); // EXPECT_ERROR: E_RESOURCE_LEAK
        if flag {
            continue;          // t leaks on the continue edge
        }
        let a: u32 = consume(t);
    }
    return 0;
}

// Consuming the body-local before `continue` is fine — nothing is live at the edge.
fn accept_loop_consume_then_continue(flag: bool) -> u32 {
    while flag {
        let t: Token = make();
        let a: u32 = consume(t);
        continue;
    }
    return 0;
}

// --- move values bound in a switch arm are tracked too (regression: ok(t) must be linear) ---

enum MoveErr { Bad }
extern fn try_make() -> Result<Token, MoveErr>;

// accepted: the arm binding is consumed exactly once
fn accept_switch_consume() -> u32 {
    switch try_make() {
        ok(t) => { return consume(t); }
        err(e) => { return 0; }
    }
}

// rejected: the bound move value is used twice inside the arm
fn reject_switch_use_after_move() -> u32 {
    switch try_make() {
        ok(t) => {
            let a: u32 = consume(t);
            return consume(t); // EXPECT_ERROR: E_USE_AFTER_MOVE
        }
        err(e) => { return 0; }
    }
}

// rejected: the bound move value is never consumed in the arm (leak)
fn reject_switch_leak() -> u32 {
    switch try_make() {
        ok(t) => { return 0; } // EXPECT_ERROR: E_RESOURCE_LEAK
        err(e) => { return 0; }
    }
}

// --- move values bound in an if-let branch are tracked too ---

fn accept_if_let_consume() -> u32 {
    if let ok(t) = try_make() {
        return consume(t);
    }
    return 0;
}

fn reject_if_let_use_after_move() -> u32 {
    if let ok(t) = try_make() {
        let a: u32 = consume(t);
        return consume(t); // EXPECT_ERROR: E_USE_AFTER_MOVE
    }
    return 0;
}

fn reject_if_let_leak() -> u32 {
    if let ok(t) = try_make() { // EXPECT_ERROR: E_RESOURCE_LEAK
        return 0;
    }
    return 0;
}

// --- a move result discarded by a bare expression statement leaks (section 18.1) ---
//
// A move-returning call (or a `?` whose ok payload is a move) used as a statement is never
// bound, returned, or consumed — the resource leaks. It must become a tracked value.

// rejected: the returned move value is discarded by a bare expression statement
fn reject_unused_move_call() -> u32 {
    // EXPECT_ERROR: E_UNUSED_MOVE_RESULT
    make();
    return 0;
}

// rejected: the `?` ok payload is a move value, discarded
fn reject_unused_move_try() -> Result<u32, MoveErr> {
    // EXPECT_ERROR: E_UNUSED_MOVE_RESULT
    try_make()?;
    return ok(0);
}

// accepted: binding the move result makes it trackable, then consumed exactly once
fn accept_bound_move_result() -> u32 {
    let t: Token = make();
    return consume(t);
}

// rejected: a move-returning expression discarded by a switch-arm body leaks, exactly like a
// bare expression statement (the arm body is evaluated only for its effect).
fn reject_unused_move_switch_arm(tag: u32) -> void {
    switch tag {
        0 => make(), // EXPECT_ERROR: E_UNUSED_MOVE_RESULT
        _ => {}
    }
}
