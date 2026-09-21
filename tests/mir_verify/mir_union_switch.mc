union Token {
    int: i64,
    ident: []const u8,
    eof,
}

type TokenAlias = Token;

fn reject_unknown_union_case(token: Token) -> void {
    switch token {
        .missing => {},
        .int => {},
        .ident => {},
        .eof => {},
    }
}

fn reject_payloadless_union_case_binding(token: Token) -> void {
    switch token {
        int(value) => {},
        ident(name) => {},
        eof(value) => {},
    }
}

fn reject_duplicate_union_case(token: TokenAlias) -> void {
    switch token {
        int(value) => {},
        .int => {},
        .ident => {},
        .eof => {},
    }
}

fn accept_union_patterns(token: TokenAlias) -> void {
    switch token {
        int(value) => {},
        ident(name) => {},
        .eof => {},
    }
}
