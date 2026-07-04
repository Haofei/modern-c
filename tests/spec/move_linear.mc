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

fn make() -> Token {
    return .{ .v = 1 };
}
fn consume(t: Token) -> u32 {
    let v: u32 = t.v;
    unsafe { forget_unchecked(t); }
    return v;
}
fn relabel(t: Token) -> Token {
    return t;
}
fn peek(t: *Token) -> u32 {
    return t.v;
}

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

fn reject_while_condition_consumes() -> u32 {
    let t: Token = make(); // EXPECT_ERROR: E_MOVE_LOOP_RESOURCE
    while consume(t) != 0 {
    }
    return 0;
}

fn accept_while_condition_borrows(flag: bool) -> u32 {
    let t: Token = make();
    while peek(&t) != 0 {
        if flag {
            break;
        }
        break;
    }
    return consume(t);
}

fn reject_logical_and_rhs_consumes(flag: bool) -> u32 {
    let t: Token = make();
    if flag && consume(t) != 0 { // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        return 1;
    }
    return 0;
}

fn reject_logical_or_rhs_consumes(flag: bool) -> u32 {
    let t: Token = make();
    if flag || consume(t) != 0 { // EXPECT_ERROR: E_MOVE_BRANCH_MISMATCH
        return 1;
    }
    return 0;
}

fn accept_logical_left_consumes(flag: bool) -> u32 {
    let t: Token = make();
    if consume(t) != 0 && flag {
        return 1;
    }
    return 0;
}

fn accept_logical_rhs_borrows(flag: bool) -> u32 {
    let t: Token = make();
    if flag && peek(&t) != 0 {
        return consume(t);
    }
    return consume(t);
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

// --- T1.2: a pointer alias derived from a moved-out value is invalidated ---
//
// `let p = &t` records `p` as a borrow alias of the tracked move binding `t`. Reading
// through `p` AFTER `t` is moved (through the alias `p`, or by deref `*p`) is a stale
// use-after-move. An alias used BEFORE the move, or an alias of a value that is never
// moved, is fine.

// accepted: the alias is read before `t` is moved (still valid)
fn accept_alias_before_move() -> u32 {
    let t: Token = make();
    let p: *Token = &t;
    let x: u32 = peek(p);   // p valid here: t not yet moved
    return consume(t) + x;  // now t is moved
}

// accepted: an alias of a value that is never moved (only borrowed) is fine
fn accept_alias_no_move() -> u32 {
    let t: Token = make();
    let p: *Token = &t;
    let x: u32 = peek(p);
    let y: u32 = peek(p);   // repeated alias reads are fine while t lives
    return consume(t) + x + y;
}

// rejected: the alias is read through (passed to a reader) AFTER t was moved
fn reject_alias_after_move() -> u32 {
    let t: Token = make();
    let p: *Token = &t;
    let a: u32 = consume(t);     // t moved out here
    let b: u32 = peek(p);        // EXPECT_ERROR: E_USE_AFTER_MOVE
    return a + b;
}

// rejected: dereferencing the stale alias after the move
fn reject_alias_deref_after_move() -> u32 {
    let t: Token = make();
    let p: *Token = &t;
    let a: u32 = consume(t);     // t moved out
    let b: u32 = (*p).v;         // EXPECT_ERROR: E_USE_AFTER_MOVE
    return a + b;
}

// rejected: copying an alias into a new binding must NOT launder the staleness.
// `let q = p;` inherits p's alias-of(t), so reading through q after t is moved is
// still a stale use-after-move. (Bug #1: previously a false negative — the copy
// dropped the alias_of and the read slipped through.)
fn reject_alias_launder_after_move() -> u32 {
    let t: Token = make();
    let p: *Token = &t;
    let q: *Token = p;           // q is a copy of the alias p; inherits alias-of(t)
    let a: u32 = consume(t);     // t moved out
    let b: u32 = peek(q);        // EXPECT_ERROR: E_USE_AFTER_MOVE
    return a + b;
}

// accepted (bug #2): REASSIGNING a borrow-alias pointer to a different referent must NOT
// turn the alias into a phantom live linear resource. `var p = &t1; p = &t2;` keeps `p` a
// borrow (re-derived from the RHS), so `p` does not "leak" at exit and both real tokens are
// consumed. Previously the `p = &t2` arm unconditionally flipped `p` live → false E_RESOURCE_LEAK.
fn accept_reassign_alias_pointer() -> u32 {
    let t1: Token = make();
    let t2: Token = make();
    var p: *Token = &t1;
    let x: u32 = peek(p);        // p aliases t1
    p = &t2;                     // p now aliases t2 — still a borrow, not a resource
    let y: u32 = peek(p);        // p aliases t2 (valid: t2 not yet moved)
    return consume(t1) + consume(t2) + x + y;
}

// rejected (bug #2 dual): after reassigning the alias to t2, reading through it once t2 is
// moved out is still a stale use-after-move — the re-derived alias tracks the NEW referent.
fn reject_reassigned_alias_after_move() -> u32 {
    let t1: Token = make();
    let t2: Token = make();
    var p: *Token = &t1;
    p = &t2;                     // p now aliases t2
    let a: u32 = consume(t2);    // t2 moved out
    let b: u32 = peek(p);        // EXPECT_ERROR: E_USE_AFTER_MOVE
    return consume(t1) + a + b;
}

// --- T1.2 (bug #3): a borrow of a move binding laundered through a STRUCT FIELD ---

struct Holder {
    p: *Token,
}

// accepted: the field alias `h.p` is read while its referent `t` is still live.
fn accept_field_alias_before_move() -> u32 {
    let t: Token = make();
    let h: Holder = .{ .p = &t };
    let b: u32 = peek(h.p);      // h.p valid: t not yet moved
    return consume(t) + b;
}

// rejected: `h.p` aliases `t` (`.{ .p = &t }`); reading through it after `t` is moved out is
// a stale use-after-move laundered through the struct field. (Previously a false negative —
// the alias tracking only followed bare-ident aliases, not aliases stored in aggregate fields.)
fn reject_field_alias_after_move() -> u32 {
    let t: Token = make();
    let h: Holder = .{ .p = &t };
    let a: u32 = consume(t);     // t moved out
    let b: u32 = peek(h.p);      // EXPECT_ERROR: E_USE_AFTER_MOVE
    return a + b;
}
