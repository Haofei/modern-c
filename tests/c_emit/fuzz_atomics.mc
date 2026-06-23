// Differential-coverage fixture: `atomic<T>` load / store / fetch_add across the memory
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
    flag: atomic<u32>,
}

fn mix(x: u32) -> u32 {
    return (x << 1) ^ 0x9E37_79B9;
}

export fn atomics_run() -> u32 {
    var c: Counters = uninit;

    // store across orders
    c.a.store(0, .relaxed);
    c.b.store(0, .release);
    c.flag.store(0, .seq_cst);

    // fetch_add: relaxed accumulation; prior values captured in typed locals (see the
    // inferred-local note in the footer)
    let r0: u32 = c.a.fetch_add(5, .relaxed);     // returns prior 0
    let r1: u32 = c.a.fetch_add(37, .acq_rel);    // returns prior 5
    let r2: u32 = c.a.fetch_add(1, .seq_cst);     // returns prior 42

    // 64-bit fetch_add, prior value used in arithmetic (atomic op hoisted to a let, the
    // pattern both backends support — see the nested-position note in the fixture footer).
    let b_prev: u64 = c.b.fetch_add(0x1_0000_0001, .acq_rel);
    let b_now: u64 = c.b.load(.acquire);
    let bview: u32 = mix(((b_now + b_prev) & 0xFFFF_FFFF) as u32);

    // load across orders, used in arithmetic via hoisted lets
    let a_final: u32 = c.a.load(.acquire);   // 43
    var acc: u32 = 0;
    acc = acc ^ a_final;
    acc = acc ^ (r0 + r1 + r2);              // 0 + 5 + 42 = 47
    acc = acc ^ bview;

    // store-then-load round trip
    c.flag.store(0xABCD, .release);
    let f: u32 = c.flag.load(.acquire);
    if f == 0xABCD { acc = acc ^ 0x10000; }

    // entry-mode contract: 1 = pass, 0 = fail (snapshot also catches both-backends-identical miscompiles).
    if acc != 0x9E36_79BF { return 0; }
    return 1;

    // NOTE (C-backend parity follow-up, tracked in docs/lowering-coverage.md): the C
    // backend raises UnsupportedCEmission for some atomic-result uses that LLVM lowers —
    // (a) an `atomic.load()` nested directly inside a compound expression (call argument /
    // arithmetic operand), and (b) an INFERRED-type local bound to an atomic op
    // (`let r = x.fetch_add(..)`) when later combined in a multi-term expression. Both are
    // emission limitations, not silent miscompiles. MMIO reads ARE hoisted in those
    // positions (see fuzz_mmio_read_positions.mc); atomic reads are not. This fixture uses
    // typed atomic-result locals at let/statement level — the form kernel code actually
    // uses (std/spinlock, std/arc) — so it is a clean cross-backend parity gate.
}
