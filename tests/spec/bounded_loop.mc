// SPEC: section=20.3
// SPEC: milestone=bounded-termination
// SPEC: phase=sema
// SPEC: expect=reject,pass
// SPEC: check=E_UNBOUNDED_LOOP,E_UNBOUNDED_RECURSION

// T(term)1 (bounded-loop / no-unbounded-recursion): a function in IRQ/atomic
// context (`#[irq_context]`/`#[atomic_context]`) — or one marked `#[bounded]` —
// must terminate; a kernel can't hang inside an interrupt. Each loop must match a
// recognized statically-bounded shape (a `for` over an array/slice, or a `while`
// whose counter advances monotonically toward a bound, or a loop with a `break`),
// and the function may not directly recurse. Static termination is undecidable in
// general — this recognizes SHAPES, not proofs, so it is opt-in via the attribute.

// ACCEPTED: a monotone counter advancing toward a constant bound.
#[irq_context]
fn drain_fifo(limit: u32) -> u32 {
    var i: u32 = 0;
    var sum: u32 = 0;
    while i < limit {
        sum = sum + i;
        i = i + 1;
    }
    return sum;
}

// ACCEPTED: (bug #4) the counter advance sits inside an `if`/`else`. A plain `if`
// desugars to a `switch` on the bool, so the advance lives in a switch arm. The
// bounded-loop walker must recurse into switch arms (it previously recursed into
// `if_let` but forgot `switch`, producing a false E_UNBOUNDED_LOOP here).
#[bounded]
fn advance_in_if(n: u32, c: bool) -> u32 {
    var i: u32 = 0;
    while i < n {
        if c {
            i = i + 1;
        } else {
            i = i + 2;
        }
    }
    return i;
}

// ACCEPTED: a decrementing counter toward zero.
#[bounded]
fn countdown(start: u32) -> u32 {
    var n: u32 = start;
    while n > 0 {
        n = n - 1;
    }
    return n;
}

// ACCEPTED: a `for` over a fixed array is finite by construction.
#[bounded]
fn sum_bytes(buf: [16]u8) -> u32 {
    var total: u32 = 0;
    for b in buf {
        total = total + 1;
    }
    return total;
}

// ACCEPTED: an unbounded-looking `while` that carries a `break` (escape hatch).
#[bounded]
fn poll_once(ready: bool) -> u32 {
    while true {
        break;
    }
    return 0;
}

// REJECTED: `while true {}` with no break — the classic interrupt hang.
#[irq_context]
fn spin_forever() -> void {
    // EXPECT_ERROR: E_UNBOUNDED_LOOP
    while true {
    }
}

// REJECTED: a `while` whose counter is never advanced toward the bound.
#[bounded]
fn never_advances(limit: u32) -> u32 {
    var i: u32 = 0;
    // EXPECT_ERROR: E_UNBOUNDED_LOOP
    while i < limit {
        i = i;
    }
    return i;
}

// REJECTED: direct self-recursion from a bounded-context function.
#[irq_context]
fn recurse(n: u32) -> u32 {
    // EXPECT_ERROR: E_UNBOUNDED_RECURSION
    return recurse(n);
}

// ACCEPTED: an ordinary (unmarked) function is unconstrained — opt-in only.
fn ordinary_spin() -> void {
    while true {
    }
}
