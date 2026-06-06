union Token {
    number: usize,
    ident: []const u8,
    eof,
}

extern fn make_token() -> Token;
extern fn make_token_from(seed: u32) -> Token;
extern fn next_seed() -> u32;

fn pass_token(token: Token) -> Token {
    return token;
}

fn make_number() -> Token {
    return number(7);
}

fn make_eof() -> Token {
    return eof();
}

fn call_pass_token() -> Token {
    return pass_token(number(9));
}

fn local_number() -> Token {
    let token: Token = number(11);
    return token;
}

fn token_value(token: Token) -> usize {
    switch token {
        number(v) => { return v; },
        ident(s) => { return s.len; },
        .eof => { return 0; },
    }
}

fn token_kind(token: Token) -> u32 {
    switch token {
        .number => { return 1; },
        .ident, .eof => { return 0; },
    }
}

fn token_call_value() -> usize {
    switch make_token() {
        number(v) => { return v; },
        _ => { return 0; },
    }
}

fn token_call_seed_value() -> usize {
    switch make_token_from(next_seed()) {
        number(v) => { return v; },
        _ => { return 0; },
    }
}
