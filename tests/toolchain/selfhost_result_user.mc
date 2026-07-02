// selfhost_result_user — behavioral fixture for mcc2's `Result<T,E>` + `?` error-propagation + Result
// pattern matching (the next self-host blocker after value optionals). It is compiled by the standalone
// mcc2 CLI to C, linked with the driver in tools/toolchain/selfhost-result-test.sh, and its exported
// functions are called + asserted. This proves the Result lowering — a tagged
// `mc_result_<T>_<E> { bool is_ok; union { T ok; E err; } payload; }` (matching the real C backend) —
// RUNS correctly through clang, not merely that it compiles. It uses no imports (no multi-file loader).
//
// Exercised: `ok(x)`/`err(x)` construction; `switch r { ok(v) => .., err(e) => .. }`; `if let ok(v)`;
// `if let err(e)`; and the postfix `expr?` propagation operator (early-returns the enclosing `err`).

// Producer: a checked division. `err(1)` on divide-by-zero, else `ok(a / b)`.
fn checked_div(a: u32, b: u32) -> Result<u32, u32> {
    if b == 0 {
        return err(1);
    }
    return ok(a / b);
}

// Consume via `switch`: the quotient on ok, or `900 + code` on err.
export fn div_or_switch(a: u32, b: u32) -> u32 {
    let r: Result<u32, u32> = checked_div(a, b);
    switch r {
        ok(v) => { return v; },
        err(e) => { return 900 + e; },
    }
    return 0;
}

// Consume via `if let ok(v)`: the quotient on ok, else the sentinel 777.
export fn div_iflet_ok(a: u32, b: u32) -> u32 {
    if let ok(v) = checked_div(a, b) {
        return v;
    }
    return 777;
}

// Consume via `if let err(e)`: `500 + code` on err, else 0.
export fn div_iflet_err(a: u32, b: u32) -> u32 {
    if let err(e) = checked_div(a, b) {
        return 500 + e;
    }
    return 0;
}

// `?` propagation: two chained divisions; the FIRST error short-circuits with the enclosing `err`.
fn chain(a: u32, b: u32, c: u32) -> Result<u32, u32> {
    let x: u32 = checked_div(a, b)?;
    let y: u32 = checked_div(x, c)?;
    return ok(y);
}

// Drive the `?`-chain and report via `switch`: the final quotient on ok, or `800 + code` on err.
export fn chain_or(a: u32, b: u32, c: u32) -> u32 {
    let r: Result<u32, u32> = chain(a, b, c);
    switch r {
        ok(v) => { return v; },
        err(e) => { return 800 + e; },
    }
    return 0;
}
