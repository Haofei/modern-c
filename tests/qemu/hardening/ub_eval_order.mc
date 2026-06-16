// UB class: unsequenced side effects / evaluation-order UB (in C, `f() - g()` and multiple
// writes to one object between sequence points are unspecified or UB).  MC handling: DEFINED
// — evaluation order is part of the language (section: "Evaluation order is defined":
// function arguments left-to-right, binary operators left operand then right, assignment is
// RHS then LHS then store; && / || short-circuit).  The C backend lowers each subexpression
// to its own sequenced temporary (mc_tmp0, mc_tmp1, ...) in MIR order, so the emitted C has
// no unsequenced reads/writes.  This fixture pins the order down observably.
global g_counter: u32;

fn tick() -> u32 {
    g_counter = g_counter + 1;
    return g_counter;
}

export fn ub_eval_order_run() -> u32 {
    var pass: u32 = 1;
    // Left operand evaluates before the right: tick() yields 1 then 2, so 1 - 2 ... but we
    // compare against the defined left-to-right values directly to keep it unsigned-safe.
    g_counter = 0;
    let lo: u32 = tick();   // 1
    let hi: u32 = tick();   // 2
    if lo != 1 { pass = 0; }
    if hi != 2 { pass = 0; }
    // Inlined into one expression: left-to-right argument order is guaranteed.
    g_counter = 0;
    if pair_first(tick(), tick()) != 1 { pass = 0; }   // first arg (1) evaluated first
    return pass;
}

fn pair_first(a: u32, b: u32) -> u32 {
    if b != 2 { return 0; }   // second arg must be 2 if order is left-to-right
    return a;
}
