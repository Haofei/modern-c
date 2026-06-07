// SPEC: section=18.1
// SPEC: milestone=linear-move
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_USE_AFTER_MOVE,E_RESOURCE_LEAK

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
