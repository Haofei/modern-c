// Runtime proof (G7) that labeled `break :L` / `continue :L` target the NAMED
// enclosing loop rather than the innermost one, on BOTH backends. Each labeled
// case is paired with a byte-identical BARE case; the two produce DIFFERENT
// accumulators, so the checksum only matches when the label actually redirects
// the jump to the outer loop. If labels were (wrongly) ignored and treated as
// innermost, acc_break_labeled would equal acc_break_bare and acc_cont_labeled
// would equal acc_cont_bare, changing the checksum and failing the run.

// `break :outer1` from the inner loop exits BOTH loops at a=0,b=2 -> 2 iters.
fn break_labeled() -> u32 {
    var a: u32 = 0;
    var acc: u32 = 0;
    outer1: while a < 4 {
        var b: u32 = 0;
        while b < 4 {
            if b == 2 { break :outer1; }
            acc = acc + 1;
            b = b + 1;
        }
        a = a + 1;
    }
    return acc; // 2
}

// Bare `break` exits only the inner loop: 2 iters per outer pass x 4 = 8.
fn break_bare() -> u32 {
    var c: u32 = 0;
    var acc: u32 = 0;
    while c < 4 {
        var d: u32 = 0;
        while d < 4 {
            if d == 2 { break; }
            acc = acc + 1;
            d = d + 1;
        }
        c = c + 1;
    }
    return acc; // 8
}

// `continue :outer2` jumps to the OUTER loop's next iteration, skipping the
// `acc + 100` tail after the inner loop entirely.
fn continue_labeled() -> u32 {
    var e: u32 = 0;
    var acc: u32 = 0;
    outer2: while e < 3 {
        e = e + 1;
        var f: u32 = 0;
        while f < 3 {
            f = f + 1;
            if f == 2 { continue :outer2; }
            acc = acc + 1;
        }
        acc = acc + 100; // unreachable: continue :outer2 always fires first
    }
    return acc; // 3
}

// Bare `continue` re-checks the INNER loop, so the `acc + 100` tail runs every
// outer pass.
fn continue_bare() -> u32 {
    var g: u32 = 0;
    var acc: u32 = 0;
    while g < 3 {
        g = g + 1;
        var h: u32 = 0;
        while h < 3 {
            h = h + 1;
            if h == 2 { continue; }
            acc = acc + 1;
        }
        acc = acc + 100;
    }
    return acc; // 306
}

// G7 regression: a labeled `break :o` must run the defers of EVERY loop it exits —
// the inner loop's AND the TARGET loop's. The C backend previously ran only the
// innermost loop's defers (started cleanup at the innermost mark regardless of the
// label), so this returned 101 instead of 1101; LLVM was already correct.
global g_defer: u32 = 0;
fn dadd(n: u32) -> void { g_defer = g_defer + n; }
fn defer_break_labeled() -> u32 {
    g_defer = 0;
    var i: u32 = 0;
    o: while i < 5 {
        defer dadd(1000);          // outer-loop defer
        var j: u32 = 0;
        while j < 5 {
            defer dadd(100);       // inner-loop defer
            dadd(1);
            break :o;              // unwinds inner (+100) THEN outer (+1000)
        }
        i = i + 1;
    }
    return g_defer;                // 1 + 100 + 1000 = 1101
}

export fn run() -> u32 {
    return break_labeled()          // 2
        + break_bare()              // 8
        + continue_labeled()        // 3
        + continue_bare()           // 306
        + defer_break_labeled();    // 1101
    // expect 2 + 8 + 3 + 306 + 1101 = 1420
}
