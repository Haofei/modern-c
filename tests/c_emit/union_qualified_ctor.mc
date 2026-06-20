// Namespaced (qualified) tagged-union constructors: `Union.variant(...)`. Alongside the
// bare, target-typed `variant(...)` form, a variant may be constructed through its union
// — `Token.number(11)`, `Token.eof()`. This form is SELF-TYPED (the owner names the
// union, so no target type is needed) and collision-proof: two unions may share a variant
// name and `A.x(...)` / `B.x(...)` stay distinct. Both backends must lower it identically.

union Token {
    number: u32,
    ident: []mut u8,
    eof,
}

// A second union sharing the `number` variant name — qualification disambiguates.
union Message {
    number: u8,
    reset,
}

// Self-typed: the qualified constructor needs no annotation to know its type.
fn make_number() -> Token {
    return Token.number(7);
}
fn make_eof() -> Token {
    return Token.eof();
}

// `let` with no annotation infers the union type from the qualified constructor.
fn local_inferred() -> u32 {
    let t = Token.number(9);
    switch t {
        number(v) => {
            return v;
        }
        ident(s) => {
            return s.len as u32;
        }
        .eof => {
            return 0;
        }
    }
}

// As a call argument (target type present too — the qualified form still applies).
fn pass_through(t: Token) -> Token {
    return t;
}
fn call_arg() -> Token {
    return pass_through(Token.number(11));
}

// The same variant name on a different union resolves to that union, no ambiguity.
fn make_message() -> Message {
    return Message.number(3);
}

// The bare, target-typed form still works unchanged.
fn bare_form() -> Token {
    return number(13);
}
