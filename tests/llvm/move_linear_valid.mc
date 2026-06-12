move struct Token {
    v: u32,
}

move struct Boot {
    hartid: u32,
}

move struct TrapReady {
    hartid: u32,
}

extern fn make_token() -> Token;
extern fn consume_token(t: Token) -> u32;
extern fn relabel_token(t: Token) -> Token;
extern fn peek_token(t: *Token) -> u32;
extern fn boot_hart(id: u32) -> Boot;

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
    drop(h);
    return .{ .hartid = id };
}

fn accept_drop_chain(id: u32) -> u32 {
    let b: Boot = boot_hart(id);
    let t: TrapReady = install_trap_vector(b);
    let final_id: u32 = t.hartid;
    drop(t);
    return final_id;
}
