// Native `#[test]` functions, run process-isolated by tools/test/mc-test-runner.sh.
// Each is a `#[test] export fn name() -> u32` that `assert(...)`s the behaviour under
// test and returns 1. A failing assert traps, so the runner reports exactly which named
// test failed — no hand-rolled `pass` accumulator that hides the culprit.
//
// This is the testing facility itself (discovery via `mcc list-tests`, isolation +
// per-name reporting via the runner); the asserts double as small behavioural checks.

fn add(a: u32, b: u32) -> u32 {
    return a + b;
}

fn wrap_add(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
    return a + b;
}

enum Color {
    Red,
    Green,
    Blue,
}

fn rank(c: Color) -> u32 {
    return switch c { .Red => 1, .Green => 2, .Blue => 3 };
}

union Token {
    number: u32,
    eof,
}

fn token_value(t: Token) -> u32 {
    switch t {
        number(v) => {
            return v;
        }
        .eof => {
            return 0;
        }
    }
}

#[test]
export fn checked_arithmetic_adds() -> u32 {
    assert(add(40, 2) == 42);
    assert(add(0, 0) == 0);
    return 1;
}

#[test]
export fn wrap_domain_wraps() -> u32 {
    let max: wrap<u32> = 0xFFFFFFFF;
    let one: wrap<u32> = 1;
    let zero: wrap<u32> = 0;
    assert(wrap_add(max, one) == zero); // modular wraparound
    return 1;
}

#[test]
export fn expression_switch_ranks() -> u32 {
    assert(rank(.Red) == 1);
    assert(rank(.Blue) == 3);
    return 1;
}

#[test]
export fn qualified_union_constructor() -> u32 {
    assert(token_value(Token.number(11)) == 11); // namespaced constructor
    assert(token_value(Token.eof()) == 0);
    return 1;
}

// A linear `move` resource whose completion needs no release: `#[trivial_drop]` makes
// `drop(t)` a safe final use (no `unsafe { forget_unchecked }`).
#[trivial_drop]
opaque move struct Ticket {
    id: u32,
}

impl Ticket {
    fn issue(n: u32) -> Ticket {
        return .{ .id = n };
    }
    fn redeem(t: Ticket) -> u32 {
        let v: u32 = t.id;
        drop(t); // safe — Ticket is #[trivial_drop]
        return v;
    }
}

#[test]
export fn trivial_drop_linear_resource() -> u32 {
    let t: Ticket = Ticket.issue(7);
    let v: u32 = Ticket.redeem(t); // consumes the linear Ticket (drop inside is safe)
    assert(v == 7);
    return 1;
}
