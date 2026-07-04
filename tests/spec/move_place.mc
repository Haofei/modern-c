// SPEC: section=18.1
// SPEC: milestone=linear-move
// SPEC: phase=sema
// SPEC: expect=pass,compile_error
// SPEC: check=E_USE_AFTER_MOVE

// Place sensitivity (review issue #2): a `move` struct can have its `move` fields moved
// out one at a time. Moving a field poisons that place, so a second move (or a borrow) of
// the same field is use-after-move, and moving the whole aggregate after a field was taken
// is rejected (it would duplicate the field). `forget_unchecked` discards the husk and is
// allowed after a partial move.

move struct Res { v: u32 }
move struct Pair { a: Res, b: Res }
move struct Nest { p: Pair }

fn mkres(v: u32) -> Res {
    return .{ .v = v };
}
fn mk() -> Pair {
    return .{ .a = mkres(1), .b = mkres(2) };
}
fn mknest() -> Nest {
    return .{ .p = mk() };
}
fn consume(r: Res) -> u32 {
    let v: u32 = r.v;
    unsafe { forget_unchecked(r); }
    return v;
}
fn peek(r: *Res) -> u32 {
    return r.v;
}
fn take_whole(p: Pair) -> u32 {
    let a: Res = p.a;
    let b: Res = p.b;
    unsafe { forget_unchecked(p); }
    return consume(a) + consume(b);
}

// Rejected: a nested place (n.p.a) moved twice — place tracking is not just one level deep.
fn reject_nested_field_move() -> u32 {
    let n: Nest = mknest();
    let x: Res = n.p.a;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = n.p.a;
    unsafe { forget_unchecked(n); } // discard the rest of the husk so only the dup is reported
    return consume(x) + consume(y);
}

// Accepted: move each field out exactly once, then discard the empty husk.
fn accept_move_each_field() -> u32 {
    let p: Pair = mk();
    let x: Res = p.a;
    let y: Res = p.b;
    unsafe { forget_unchecked(p); }
    return consume(x) + consume(y);
}

// Rejected: moving the same field twice duplicates the resource.
fn reject_duplicate_field_move() -> u32 {
    let p: Pair = mk();
    let x: Res = p.a;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let y: Res = p.a;
    unsafe { forget_unchecked(p); }
    return consume(x) + consume(y);
}

// Rejected: borrowing a field after it was moved out.
fn reject_borrow_after_field_move() -> u32 {
    let p: Pair = mk();
    let x: Res = p.a;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let v: u32 = peek(&p.a);
    unsafe { forget_unchecked(p); }
    return consume(x) + v;
}

// Rejected: moving the whole aggregate after a field was already taken.
fn reject_whole_after_partial() -> u32 {
    let p: Pair = mk();
    let x: Res = p.a;
    // EXPECT_ERROR: E_USE_AFTER_MOVE
    let r: u32 = take_whole(p);
    return consume(x) + r;
}
