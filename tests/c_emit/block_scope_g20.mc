// Differential-coverage fixture (language gap G20: block-scoped `let`/`var` locals).
// A local declared inside a block is scoped to that block, so a DISJOINT sibling block
// may reuse the same name for a DISTINCT binding (its own type/value) without an
// E_DUPLICATE_LOCAL. Re-declaring a name STILL LIVE in an enclosing scope stays rejected
// (see tests/spec/block_scope_shadow_g20.mc) — MC forbids live-shadowing. Each backend
// must lower the two same-named siblings to DISTINCT storage, so a wrong-variable bug
// (reading the other block's `t`) changes the folded result and makes the entry return 0.

// Two disjoint `while` bodies each declare `let t` — the ORIGINAL repro. They compute
// different accumulations, so a collapsed-into-one-variable lowering would diverge.
fn two_while_siblings(n: u32) -> u32 {
    var acc: u32 = 0;
    while acc < n {
        let t: u32 = acc;
        acc = acc + t + 1;
    }
    while acc > 10 {
        let t: u32 = acc;
        acc = acc - t + 5;
    }
    return acc;
}

// Sibling `{ ... }` blocks reuse `t` at DIFFERENT types (u32 vs u64), each folded into a
// running total. Distinct storage is required or the second read sees the first's bits.
fn sibling_blocks_distinct_types() -> u32 {
    var total: u32 = 0;
    {
        let t: u32 = 3;
        total = total + t;        // +3
    }
    {
        let t: u64 = 40;
        total = total + (t as u32); // +40
    }
    {
        var t: u32 = 100;
        t = t + 1;
        total = total + t;        // +101
    }
    return total;                 // 144
}

// A `for`-loop element name reused across sibling loops, and a block-local `t` after them.
fn sibling_for_and_block() -> u32 {
    let xs: [3]u32 = .{ 10, 20, 30 };
    var sum: u32 = 0;
    for v in xs { sum = sum + v; } // 60
    for v in xs { sum = sum + v; } // 120  (sibling reuse of `v`)
    {
        let v: u32 = 5;
        sum = sum + v;             // 125  (block reuse of `v` after the loops)
    }
    return sum;                    // 125
}

// Nested block reuse: an inner sibling `t` distinct from the outer block-local `t`, both
// live at different points. Reusing after the inner block closes must be accepted.
fn nested_then_sibling() -> u32 {
    var out: u32 = 0;
    {
        let t: u32 = 7;
        {
            let inner: u32 = t + 1; // 8, reads the enclosing t
            out = out + inner;      // +8
        }
        out = out + t;              // +7
    }
    {
        let t: u32 = 2;             // sibling of the first block's t
        out = out + t;              // +2
    }
    return out;                     // 17
}

export fn block_scope_g20_run() -> u32 {
    // two_while_siblings(4): loop1 runs t=0->acc1, t=1->acc3, t=3->acc7 (acc<4 stops at 7);
    // loop2: acc>10 is false at 7, so no change. Result 7.
    if two_while_siblings(4) != 7 { return 0; }
    // two_while_siblings(20): loop1 → acc 1,3,7,15,31 (stops ≥20); loop2 (acc>10): t=31,
    // acc=31-31+5=5, then 5>10 false. Result 5 — pins that loop2's `t` is its OWN binding.
    if two_while_siblings(20) != 5 { return 0; }
    if sibling_blocks_distinct_types() != 144 { return 0; }
    if sibling_for_and_block() != 125 { return 0; }
    if nested_then_sibling() != 17 { return 0; }
    return 1;
}
