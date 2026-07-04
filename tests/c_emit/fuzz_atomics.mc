// Differential-coverage fixture: `atomic<T>` load / store / fetch_add / fetch_sub across the memory
// orders, in the syntactic positions the differential corpus otherwise never exercises
// (the atomicAccess / order-synchronizes / atomic-init lowering family in
// docs/lowering-coverage.md). Atomics are host-runnable — `atomic<T>` lowers to the C/LLVM
// __atomic_* builtins — so a single thread of well-ordered ops has a deterministic result
// the two backends must agree on. Entry mode diffs the C and LLVM return value, so a
// divergence in how either backend lowers an atomic op (operation, order, or the value in a
// call-arg / inferred-local position) makes the outputs disagree.

struct Counters {
    a: atomic<u32>,
    b: atomic<u64>,
    s: atomic<i64>,
    flag: atomic<u32>,
}

fn mix(x: u32) -> u32 {
    return (x << 1) ^ 0x9E37_79B9;
}

export fn atomics_run() -> u32 {
    var c: Counters = uninit;

    // store across orders
    c.a.store(0, .relaxed);
    c.b.store(0x1_0000_0000, .release);
    c.s.store(-9, .release);
    c.flag.store(0, .seq_cst);

    // fetch_add: relaxed accumulation; prior values captured in inferred locals.
    let r0 = c.a.fetch_add(5, .relaxed);     // returns prior 0
    let r1 = c.a.fetch_add(37, .acq_rel);    // returns prior 5
    let r2 = c.a.fetch_add(1, .seq_cst);     // returns prior 42

    // Inferred atomic RMW locals must keep the payload type: `b_prev` is u64
    // and `s_prev` is signed i64. A C fallback to uint32_t loses high bits/sign.
    let b_prev = c.b.fetch_add(0x1_0000_0001, .acq_rel);
    let b_now: u64 = c.b.load(.acquire);
    let bview: u32 = mix(((b_now + b_prev) & 0xFFFF_FFFF) as u32);
    let s_prev = c.s.fetch_sub(4, .acq_rel);

    // load across orders, used in arithmetic via hoisted lets
    let a_final: u32 = c.a.load(.acquire);   // 43
    var acc: u32 = 0;
    acc = acc ^ a_final;
    acc = acc ^ (r0 + r1 + r2);              // 0 + 5 + 42 = 47
    acc = acc ^ bview;
    if b_prev > 0xFFFF_FFFF { acc = acc ^ 0x20000; }
    if s_prev < 0 { acc = acc ^ 0x40000; }

    // store-then-load round trip
    c.flag.store(0xABCD, .release);
    let f: u32 = c.flag.load(.acquire);
    if f == 0xABCD { acc = acc ^ 0x10000; }

    // entry-mode contract: 1 = pass, 0 = fail (snapshot also catches both-backends-identical miscompiles).
    if acc != 0x9E30_79BF { return 0; }
    return 1;

    // NOTE (C-backend parity follow-up, tracked in docs/lowering-coverage.md):
    // nested atomic result expressions still need the same temp-hoisting policy as
    // MMIO reads. This fixture keeps RMW results in statement-level inferred locals,
    // which should lower to payload-typed C locals before they feed later expressions.
}
