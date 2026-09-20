// A local of POINTER type borrows what it points at; it does not own it.
//
// MIR resolved a local's owning type by looking through a pointer, so
// `var p: *Token` was recorded as owning a `Token`. That gave `p` an ownership
// obligation it never had: reassigning it (`p = &t2`) emitted a `reinit` on a
// root the sequence validator already considered live, and the whole function
// was rejected with an internal InvalidMirOwnershipEvents rather than a
// diagnostic. A borrow has no obligation -- it may be repointed freely, and it
// never drops its referent -- so it must not be an ownership root at all.
//
// This fixture takes a borrow of a move-typed value, uses it, repoints it at a
// second value, uses it again, and then consumes both values exactly once. It
// reads through each borrow before and after the reassignment to prove the
// alias really tracks the value it names.

move struct Token { v: u32 }

fn make(v: u32) -> Token {
    return .{ .v = v };
}

fn consume(t: Token) -> u32 {
    let v: u32 = t.v;
    unsafe { forget_unchecked(t); }
    return v;
}

fn peek(t: *Token) -> u32 {
    return t.v;
}

// The borrow alias is repointed mid-function. Both tokens stay live until they
// are moved, and each is consumed exactly once.
fn reassign_alias_pointer() -> u32 {
    let t1: Token = make(10);
    let t2: Token = make(20);
    var p: *Token = &t1;
    let x: u32 = peek(p);        // p aliases t1
    p = &t2;                     // still a borrow, now of t2
    let y: u32 = peek(p);        // p aliases t2
    return consume(move t1) + consume(move t2) + x + y;
}

export fn move_borrow_alias_run() -> u32 {
    // consume(t1) + consume(t2) + peek-before + peek-after = 10 + 20 + 10 + 20
    if reassign_alias_pointer() != 60 { return 0; }
    return 1;
}
