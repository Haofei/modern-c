// G11 expression-`switch` (parse-time sugar): `return switch …` and
// `var/let x: T = switch …` desugar into the existing statement-`switch`
// (return / single-assignment arms), so exhaustiveness, payload bindings, and
// both backends are reused unchanged. Arms are value expressions, not blocks.

enum Color { Red, Green, Blue }

// return-position expression switch over a closed enum (exhaustive).
fn rank(c: Color) -> u64 {
    return switch c { .Red => 1, .Green => 2, .Blue => 3 };
}

// var initializer-position expression switch.
fn rank_var(c: Color) -> u64 {
    var r: u64 = switch c { .Red => 10, .Green => 20, .Blue => 30 };
    return r;
}

// let initializer-position — the binding stays immutable; only the synthesized
// temp is assigned, exactly once on every arm.
fn rank_let(c: Color) -> u64 {
    let r: u64 = switch c { .Red => 100, .Green => 200, .Blue => 300 };
    return r;
}

// payload-binding arms: Result ok(v)/err(e).
fn unwrap_or_zero(x: Result<u32, u32>) -> u64 {
    return switch x { ok(v) => (v as u64), err(e) => (e as u64) };
}

// payload-binding arms: tagged union, with a no-payload dotted case.
union Token {
    num: u32,
    wide: u64,
    end,
}

fn token_value(t: Token) -> u64 {
    let v: u64 = switch t { num(n) => (n as u64), wide(w) => w, .end => 0 };
    return v;
}
