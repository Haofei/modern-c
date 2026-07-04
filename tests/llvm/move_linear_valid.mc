move struct Token {
    v: u32,
}

move struct Boot {
    hartid: u32,
}

move struct TrapReady {
    hartid: u32,
}

fn make_token() -> Token {
    return .{ .v = 1 };
}

fn consume_token(t: Token) -> u32 {
    let v: u32 = t.v;
    unsafe { forget_unchecked(t); }
    return v;
}

fn relabel_token(t: Token) -> Token {
    return t;
}

extern fn peek_token(t: *Token) -> u32;

fn boot_hart(id: u32) -> Boot {
    return .{ .hartid = id };
}

fn accept_consume_once() -> u32 {
    let t: Token = make_token();
    return consume_token(t);
}

fn accept_transition_distinct() -> u32 {
    let a: Token = make_token();
    let b: Token = relabel_token(a);
    return consume_token(b);
}

fn accept_borrow_then_consume() -> u32 {
    let t: Token = make_token();
    let x: u32 = peek_token(&t);
    return consume_token(t) + x;
}

fn install_trap_vector(h: Boot) -> TrapReady {
    let id: u32 = h.hartid;
    unsafe { forget_unchecked(h); }
    return .{ .hartid = id };
}

fn accept_drop_chain(id: u32) -> u32 {
    let b: Boot = boot_hart(id);
    let t: TrapReady = install_trap_vector(b);
    let final_id: u32 = t.hartid;
    unsafe { forget_unchecked(t); }
    return final_id;
}
