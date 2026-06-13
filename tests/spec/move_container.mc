// SPEC: section=18.1
// SPEC: milestone=linear-move
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_USE_AFTER_MOVE,E_RESOURCE_LEAK,E_MOVE_ARRAY_UNSUPPORTED

// A linear `move` resource embedded by value in a built-in container — a Result payload, a
// nullable, or an array — must still be tracked. A binding of such a type is consumed once;
// an array of a move type is rejected until element-place analysis exists.

move struct Token { v: u32 }
enum E { Bad }

extern fn make() -> Token;
extern fn consume(t: Token) -> u32;

// --- accepted: a Result<Token,E> binding consumed once (the switch moves the payload out) ---
fn accept_result_once() -> u32 {
    let r: Result<Token, E> = ok(make());
    switch r {
        ok(t) => { return consume(t); }
        err(e) => { return 0; }
    }
}

// --- accepted: a Result with a non-move payload is not a tracked resource ---
fn accept_plain_result(b: bool) -> u32 {
    let r: Result<bool, E> = ok(b);
    switch r {
        ok(v) => { return 1; }
        err(e) => { return 0; }
    }
}

// --- rejected: a Result<Token,E> binding used by two switches duplicates the payload ---
fn reject_result_twice() -> u32 {
    let r: Result<Token, E> = ok(make());
    var s: u32 = 0;
    switch r {
        ok(t) => { s = consume(t); }
        err(e) => {}
    }
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    switch r {
        ok(t) => { s = s + consume(t); }
        err(e) => {}
    }
    return s;
}

// --- rejected: a nullable move payload that is never consumed leaks ---
fn reject_opt_leak() -> u32 {
    // EXPECT_ERROR: E_RESOURCE_LEAK
    let o: ?Token = make();
    return 0;
}

// --- rejected: an array of a move type is not yet trackable ---
fn reject_move_array() -> u32 {
    // EXPECT_ERROR: E_MOVE_ARRAY_UNSUPPORTED
    var arr: [2]Token = .{ make(), make() };
    return 0;
}
