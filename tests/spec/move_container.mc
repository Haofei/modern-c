// SPEC: section=18.1
// SPEC: milestone=linear-move
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_USE_AFTER_MOVE,E_RESOURCE_LEAK,E_MOVE_ARRAY_UNSUPPORTED,E_DROP_LINEAR_RESOURCE

// A linear `move` resource embedded by value in a built-in container — a Result payload, a
// nullable, or an array — must still be tracked. A binding of such a type is consumed once;
// an array of a move type is rejected until element-place analysis exists.

move struct Token { v: u32 }
enum E { Bad }

fn make() -> Token {
    return .{ .v = 1 };
}
fn consume(t: Token) -> u32 {
    let v: u32 = t.v;
    unsafe { forget_unchecked(t); }
    return v;
}

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

// --- rejected: drop of a wrapper that embeds a move resource frees nothing (recursive
//     containment, not just a direct move type name) ---
extern fn make_opt() -> ?Token;
extern fn make_res() -> Result<Token, E>;

fn reject_drop_optional_move() -> void {
    // EXPECT_ERROR: E_DROP_LINEAR_RESOURCE
    drop(make_opt());
}

fn reject_drop_result_move() -> void {
    // EXPECT_ERROR: E_DROP_LINEAR_RESOURCE
    drop(make_res());
}

// --- rejected: a switch-arm payload that itself embeds a move (Result<?Token,E> → ?Token) is
//     tracked like any linear binding; leaving it unconsumed leaks ---
extern fn make_nested() -> Result<?Token, E>;

fn reject_switch_wrapper_payload_leak() -> u32 {
    switch make_nested() {
        ok(x) => { return 0; } // EXPECT_ERROR: E_RESOURCE_LEAK
        err(e) => { return 0; }
    }
}

// --- rejected: a wrapper field (?Token) is a move place too, so moving it out of an aggregate
//     twice is a double move — even though ?Token is not a direct move type *name* ---
move struct OptBox { item: ?Token }
extern fn consume_opt(o: ?Token) -> u32;

fn reject_wrapper_field_double_move(b: OptBox) -> u32 {
    let a: ?Token = b.item;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let c: ?Token = b.item;
    let x: u32 = consume_opt(a) + consume_opt(c);
    unsafe { forget_unchecked(b); }
    return x;
}
