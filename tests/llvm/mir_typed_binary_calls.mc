// test: emit-llvm
// target: riscv64
// expect: pass

type S = serial<u32>;
type T = counter<u64>;

#[no_lang_trap]
fn wrap_add(a: wrap<u32>, b: wrap<u32>) -> wrap<u32> {
    return wrapping.add(a, b);
}

fn seq_before(a: S, b: S) -> bool {
    return S.before(a, b);
}

fn seq_after(a: S, b: S) -> bool {
    return S.after(a, b);
}

fn seq_distance(a: S, b: S) -> wrap<u32> {
    return S.distance(a, b);
}

fn tick_delta(now: T, start: T) -> wrap<u64> {
    return T.delta_mod(now, start);
}
